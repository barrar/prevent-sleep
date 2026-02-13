import Foundation
import Combine
import Darwin

final class AppState: ObservableObject {
    @Published var rules: [SleepRule] {
        didSet {
            guard didFinishInitialization else { return }
            pruneDisabledRuleRuntimeState()
            persistState()
            reevaluateState()
        }
    }

    @Published var globalSettings: GlobalSettings {
        didSet {
            guard didFinishInitialization else { return }
            persistState()
            reevaluateState()
        }
    }

    @Published private(set) var runningProcesses: [ProcessSnapshot] = []
    @Published private(set) var visibleWindows: [WindowSnapshot] = []
    @Published private(set) var matchedRuleIDs: Set<UUID> = []
    @Published private(set) var matchedRuleDetailsByRuleID: [UUID: [RuleMatchDetail]] = [:]
    @Published private(set) var postExitTimerEndDates: [UUID: Date] = [:]
    @Published private(set) var isSleepCurrentlyPrevented: Bool = false
    @Published private(set) var launchAtLoginEnabled: Bool = false
    @Published private(set) var privilegedAccessAvailable: Bool = false
    @Published private(set) var privilegedStatusMessage: String = "Privileged setup not checked yet."
    @Published private(set) var screenRecordingAccessAvailable: Bool = false
    @Published private(set) var screenRecordingStatusMessage: String = "Screen Recording status not checked yet."
    @Published private(set) var privilegedSetupInProgress: Bool = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var currentSystemPeakCPUUsageLastMinutePercent: Double?

    private let sleepController: SleepAssertionControlling
    private let processScanner: ProcessScanning
    private let windowScanner: WindowScanning
    private let cpuSampler: CPUUsageSampling
    private let lidMonitor: LidStateMonitoring
    private let privilegedPowerController: PrivilegedPowerControlling
    private let ruleStore: RuleStoring
    private let loginItemController: LoginItemControlling
    private let executablePathForPIDProvider: (Int32) -> String?
    private let nowProvider: () -> Date
    private let privilegedSetupQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "preventsleep.privileged-setup"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private var scanTimer: Timer?
    private var tickTimer: Timer?
    private var didFinishInitialization = false

    private var previousMatchState: [UUID: Bool] = [:]
    private var lidDelayReleaseDate: Date?
    private var lidOverrideEngaged: Bool = false
    private var systemCPUUsageHistory: [CPUSample] = []
    private var ruleCPUUsageHistoryByRuleID: [UUID: [CPUSample]] = [:]

    private let cpuPeakWindowForDisplaySeconds: TimeInterval = 60
    private let cpuPeakWindowForRuleReleaseSeconds: TimeInterval = 5 * 60

    init(
        sleepController: SleepAssertionControlling = SleepAssertionController(),
        processScanner: ProcessScanning = ProcessScanner(),
        windowScanner: WindowScanning = WindowScanner(),
        cpuSampler: CPUUsageSampling = SystemCPUSampler(),
        lidMonitor: LidStateMonitoring = LidStateMonitor(),
        privilegedPowerController: PrivilegedPowerControlling = PrivilegedPowerController(),
        ruleStore: RuleStoring = RuleStore(),
        loginItemController: LoginItemControlling = LoginItemController(),
        executablePathForPIDProvider: @escaping (Int32) -> String? = AppState.defaultExecutablePathForPID,
        nowProvider: @escaping () -> Date = Date.init,
        autoStartMonitoring: Bool = true
    ) {
        self.sleepController = sleepController
        self.processScanner = processScanner
        self.windowScanner = windowScanner
        self.cpuSampler = cpuSampler
        self.lidMonitor = lidMonitor
        self.privilegedPowerController = privilegedPowerController
        self.ruleStore = ruleStore
        self.loginItemController = loginItemController
        self.executablePathForPIDProvider = executablePathForPIDProvider
        self.nowProvider = nowProvider

        let persisted = ruleStore.loadState()
        self.rules = persisted.rules
        self.globalSettings = persisted.globalSettings
        self.lidOverrideEngaged = persisted.lidOverrideActive

        configureLidMonitor()
        didFinishInitialization = true

        launchAtLoginEnabled = loginItemController.isEnabled()
        refreshPrivilegedAccessStatus()
        refreshScreenRecordingAccessStatus()

        recoverLidOverrideIfNeeded()
        performFullScan()

        if autoStartMonitoring {
            startTimers()
            lidMonitor.start()
        }
    }

    deinit {
        scanTimer?.invalidate()
        tickTimer?.invalidate()
        lidMonitor.stop()
    }

    // MARK: - Menu/Settings Derived State

    var enabledRules: [SleepRule] {
        rules
            .filter(\.enabled)
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    var manualTimerRemainingSeconds: TimeInterval? {
        guard let endDate = globalSettings.manualTimerEndDate else { return nil }
        let remaining = endDate.timeIntervalSince(nowProvider())
        return remaining > 0 ? remaining : nil
    }

    var manualTimerRemainingLabel: String? {
        guard let remaining = manualTimerRemainingSeconds else { return nil }
        return DurationFormatter.format(seconds: remaining)
    }

    var activePostExitRules: [SleepRule] {
        let now = nowProvider()
        return rules.filter { rule in
            guard let endDate = postExitTimerEndDates[rule.id] else { return false }
            return endDate > now
        }
    }

    func postExitTimerRemainingLabel(for ruleID: UUID) -> String? {
        guard let endDate = postExitTimerEndDates[ruleID] else { return nil }
        let remaining = endDate.timeIntervalSince(nowProvider())
        guard remaining > 0 else { return nil }
        return DurationFormatter.format(seconds: remaining)
    }

    func isRuleCurrentlyMatched(_ ruleID: UUID) -> Bool {
        matchedRuleIDs.contains(ruleID)
    }

    func ruleMatchDetails(for ruleID: UUID) -> [RuleMatchDetail] {
        matchedRuleDetailsByRuleID[ruleID] ?? []
    }

    func rulePeakCPUUsageLastMinutePercent(for ruleID: UUID) -> Double? {
        peakCPUUsage(
            in: ruleCPUUsageHistoryByRuleID[ruleID] ?? [],
            within: cpuPeakWindowForDisplaySeconds,
            at: nowProvider()
        )
    }

    func isProcessWatched(_ process: ProcessSnapshot) -> Bool {
        let normalized = normalizeMatchValue(process.executablePath)
        return rules.contains { rule in
            rule.enabled && rule.matchMode == .executablePath && normalizeMatchValue(rule.matchValue) == normalized
        }
    }

    // MARK: - Top-Level Actions

    func setPreventIndefinitely(_ enabled: Bool) {
        globalSettings.preventIndefinitely = enabled
    }

    func setSleepMode(_ mode: SleepMode) {
        globalSettings.sleepMode = mode
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItemController.setEnabled(enabled)
            launchAtLoginEnabled = loginItemController.isEnabled()
        } catch {
            launchAtLoginEnabled = loginItemController.isEnabled()
            lastErrorMessage = "Failed to change Launch at Login: \(error.localizedDescription)"
        }
    }

    func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = loginItemController.isEnabled()
    }

    func setManualTimer(durationSeconds: TimeInterval) {
        let duration = max(durationSeconds, 0)
        if duration == 0 {
            globalSettings.manualTimerEndDate = nil
            return
        }

        globalSettings.manualTimerEndDate = nowProvider().addingTimeInterval(duration)
    }

    func clearManualTimer() {
        globalSettings.manualTimerEndDate = nil
    }

    func toggleRuleForRunningProcess(_ process: ProcessSnapshot) {
        let normalizedPath = normalizeMatchValue(process.executablePath)

        if let index = rules.firstIndex(where: {
            $0.matchMode == .executablePath && normalizeMatchValue($0.matchValue) == normalizedPath
        }) {
            rules[index].enabled.toggle()
            if !rules[index].enabled {
                postExitTimerEndDates.removeValue(forKey: rules[index].id)
                previousMatchState[rules[index].id] = false
                ruleCPUUsageHistoryByRuleID.removeValue(forKey: rules[index].id)
            }
            return
        }

        let rule = SleepRule(
            enabled: true,
            label: process.processName,
            matchMode: .executablePath,
            matchValue: normalizedPath,
            titleOperator: nil,
            preventWhileMatched: true,
            keepAwakeAfterExitSeconds: 0,
            lidDelaySeconds: 0
        )
        rules.append(rule)
    }

    func disableEnabledRuleFromMenu(_ ruleID: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        rules[index].enabled = false
        postExitTimerEndDates.removeValue(forKey: ruleID)
        previousMatchState[ruleID] = false
        ruleCPUUsageHistoryByRuleID.removeValue(forKey: ruleID)
    }

    func addRule() {
        let newRule = SleepRule(
            enabled: false,
            label: "New Rule",
            matchMode: globalSettings.defaultNewRuleMatchMode,
            matchValue: "",
            titleOperator: .contains,
            preventWhileMatched: true,
            keepAwakeAfterExitSeconds: 0,
            lidDelaySeconds: 0
        )
        rules.append(newRule)
    }

    func duplicateRule(_ ruleID: UUID) {
        guard let rule = rules.first(where: { $0.id == ruleID }) else { return }
        var copy = rule
        copy.id = UUID()
        copy.label = "\(rule.label) Copy"
        rules.append(copy)
    }

    func deleteRule(_ ruleID: UUID) {
        rules.removeAll { $0.id == ruleID }
        postExitTimerEndDates.removeValue(forKey: ruleID)
        previousMatchState.removeValue(forKey: ruleID)
        ruleCPUUsageHistoryByRuleID.removeValue(forKey: ruleID)
    }

    func setDefaultRuleMatchMode(_ mode: MatchMode) {
        globalSettings.defaultNewRuleMatchMode = mode
    }

    func setGlobalLidDelay(enabled: Bool, seconds: TimeInterval) {
        globalSettings.globalLidDelayEnabled = enabled
        globalSettings.globalLidDelaySeconds = max(seconds, 0)
    }

    func setGlobalCPUAllowance(enabled: Bool, thresholdPercent: Double) {
        globalSettings.allowSleepWhenSystemCPUBelowThreshold = enabled
        globalSettings.systemCPUUsageThresholdPercent = max(thresholdPercent, 0)
    }

    func installPrivilegedAccess() {
        guard !privilegedSetupInProgress else { return }

        privilegedSetupInProgress = true
        lastErrorMessage = nil

        privilegedSetupQueue.addOperation { [weak self] in
            guard let self else { return }
            let setupResult = self.privilegedPowerController.installPrivilegedAccess()
            let hasAccess = self.privilegedPowerController.hasNonInteractiveAccess()

            OperationQueue.main.addOperation { [weak self] in
                guard let self else { return }
                self.privilegedSetupInProgress = false

                switch setupResult {
                case .success:
                    self.updatePrivilegedStatus(hasAccess: hasAccess)
                    self.lastErrorMessage = nil
                case .cancelled:
                    self.lastErrorMessage = "Privileged setup cancelled."
                case .failure(let message):
                    self.updatePrivilegedStatus(hasAccess: hasAccess)
                    self.lastErrorMessage = "Privileged setup failed: \(message)"
                }
            }
        }
    }

    func refreshPrivilegedAccessStatus() {
        let available = privilegedPowerController.hasNonInteractiveAccess()
        updatePrivilegedStatus(hasAccess: available)
    }

    func requestScreenRecordingAccess() {
        let granted = windowScanner.requestScreenRecordingAccess()
        updateScreenRecordingStatus(isGranted: granted)
    }

    func refreshScreenRecordingAccessStatus() {
        let granted = windowScanner.hasScreenRecordingAccess()
        updateScreenRecordingStatus(isGranted: granted)
    }

    func refreshNow() {
        performFullScan()
        tick()
    }

    // MARK: - Runtime Loop

    private func startTimers() {
        scanTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.performFullScan()
        }

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func performFullScan() {
        refreshScreenRecordingAccessStatus()
        runningProcesses = processScanner.scanUserProcesses()
        visibleWindows = windowScanner.scanVisibleWindows()
        reevaluateMatchesAndTimers()
        recordCPUSamples()
        reevaluateState()
    }

    private func tick() {
        updatePublishedSystemCPUPeak(now: nowProvider())
        expireTimersIfNeeded()
        handleLidDelayIfNeeded()
        reevaluateState()
    }

    private func expireTimersIfNeeded() {
        let now = nowProvider()

        if let manualEnd = globalSettings.manualTimerEndDate, manualEnd <= now {
            globalSettings.manualTimerEndDate = nil
        }

        var changed = false
        for (ruleID, endDate) in postExitTimerEndDates where endDate <= now {
            postExitTimerEndDates.removeValue(forKey: ruleID)
            changed = true
        }

        if changed {
            objectWillChange.send()
        }
    }

    private func reevaluateMatchesAndTimers() {
        let evaluation = evaluateRuleMatches(rules: rules.filter(\.enabled), processes: runningProcesses, windows: visibleWindows)
        matchedRuleIDs = evaluation.matchedRuleIDs
        matchedRuleDetailsByRuleID = evaluation.ruleMatchDetails

        let now = nowProvider()
        for rule in rules where rule.enabled {
            let wasMatched = previousMatchState[rule.id] ?? false
            let isMatched = matchedRuleIDs.contains(rule.id)

            if wasMatched, !isMatched, rule.keepAwakeAfterExitSeconds > 0 {
                let endDate = now.addingTimeInterval(rule.keepAwakeAfterExitSeconds)
                postExitTimerEndDates[rule.id] = endDate
            }

            if isMatched {
                postExitTimerEndDates.removeValue(forKey: rule.id)
            } else {
                ruleCPUUsageHistoryByRuleID.removeValue(forKey: rule.id)
            }

            previousMatchState[rule.id] = isMatched
        }

        pruneDisabledRuleRuntimeState()
    }

    private func pruneDisabledRuleRuntimeState() {
        let enabledRuleIDs = Set(rules.filter(\.enabled).map(\.id))
        matchedRuleIDs = matchedRuleIDs.intersection(enabledRuleIDs)
        matchedRuleDetailsByRuleID = matchedRuleDetailsByRuleID.filter { enabledRuleIDs.contains($0.key) }
        ruleCPUUsageHistoryByRuleID = ruleCPUUsageHistoryByRuleID.filter { enabledRuleIDs.contains($0.key) }
        previousMatchState = previousMatchState.filter { enabledRuleIDs.contains($0.key) }
        postExitTimerEndDates = postExitTimerEndDates.filter { enabledRuleIDs.contains($0.key) }
    }

    private func reevaluateState() {
        let now = nowProvider()
        let manualTimerActive = (globalSettings.manualTimerEndDate?.timeIntervalSince(now) ?? 0) > 0
        let matchingPreventRuleActive = rules.contains {
            shouldPreventSleepForMatchedRule($0, at: now)
        }
        let postExitActive = postExitTimerEndDates.values.contains { $0 > now }

        var shouldPrevent = globalSettings.preventIndefinitely || manualTimerActive || matchingPreventRuleActive || postExitActive
        if shouldPrevent,
           globalSettings.allowSleepWhenSystemCPUBelowThreshold,
           let systemPeak = peakCPUUsage(in: systemCPUUsageHistory, within: cpuPeakWindowForRuleReleaseSeconds, at: now),
           systemPeak < globalSettings.systemCPUUsageThresholdPercent {
            shouldPrevent = false
        }

        isSleepCurrentlyPrevented = shouldPrevent
        sleepController.update(isNeeded: shouldPrevent, mode: globalSettings.sleepMode)
    }

    private func shouldPreventSleepForMatchedRule(_ rule: SleepRule, at now: Date) -> Bool {
        guard rule.enabled, rule.preventWhileMatched, matchedRuleIDs.contains(rule.id) else { return false }
        guard rule.allowSleepWhenCPUPeakDropsBelowThreshold else { return true }
        let ruleHistory = ruleCPUUsageHistoryByRuleID[rule.id] ?? []
        guard let peak = peakCPUUsage(in: ruleHistory, within: cpuPeakWindowForRuleReleaseSeconds, at: now) else {
            return true
        }
        return peak >= max(rule.cpuUsageThresholdPercent, 0)
    }

    private func recordCPUSamples() {
        let now = nowProvider()
        let matchedPIDs = Set(matchedRuleDetailsByRuleID.values.flatMap { $0.map(\.pid) })
        let cpuUsageSnapshot = cpuSampler.sampleCPUUsage(forPIDs: matchedPIDs)

        if let systemPercent = cpuUsageSnapshot.systemPercent {
            systemCPUUsageHistory.append(CPUSample(timestamp: now, percent: max(systemPercent, 0)))
        }

        for (ruleID, details) in matchedRuleDetailsByRuleID {
            let pids = Set(details.map(\.pid))
            var total: Double = 0
            var hasSample = false

            for pid in pids {
                guard let pidPercent = cpuUsageSnapshot.pidPercentages[pid] else { continue }
                total += max(pidPercent, 0)
                hasSample = true
            }

            guard hasSample else { continue }
            ruleCPUUsageHistoryByRuleID[ruleID, default: []].append(CPUSample(timestamp: now, percent: total))
        }

        pruneCPUHistory(now: now)
        updatePublishedSystemCPUPeak(now: now)
    }

    private func pruneCPUHistory(now: Date) {
        let maxWindow = max(cpuPeakWindowForDisplaySeconds, cpuPeakWindowForRuleReleaseSeconds)
        let cutoff = now.addingTimeInterval(-maxWindow)

        systemCPUUsageHistory.removeAll { $0.timestamp < cutoff }
        ruleCPUUsageHistoryByRuleID = ruleCPUUsageHistoryByRuleID.reduce(into: [:]) { result, pair in
            let filtered = pair.value.filter { $0.timestamp >= cutoff }
            if !filtered.isEmpty {
                result[pair.key] = filtered
            }
        }
    }

    private func updatePublishedSystemCPUPeak(now: Date) {
        pruneCPUHistory(now: now)
        currentSystemPeakCPUUsageLastMinutePercent = peakCPUUsage(
            in: systemCPUUsageHistory,
            within: cpuPeakWindowForDisplaySeconds,
            at: now
        )
    }

    private func peakCPUUsage(in history: [CPUSample], within seconds: TimeInterval, at now: Date) -> Double? {
        let cutoff = now.addingTimeInterval(-seconds)
        return history.reduce(into: nil as Double?) { peak, sample in
            guard sample.timestamp >= cutoff else { return }
            if let currentPeak = peak {
                peak = max(currentPeak, sample.percent)
            } else {
                peak = sample.percent
            }
        }
    }

    // MARK: - Lid Delay

    private func configureLidMonitor() {
        lidMonitor.onLidClosed = { [weak self] in
            self?.handleLidClosed()
        }

        lidMonitor.onLidOpened = { [weak self] in
            self?.handleLidOpened()
        }
    }

    private func handleLidClosed() {
        let delaySeconds = effectiveLidDelaySeconds()
        guard delaySeconds > 0 else { return }

        guard privilegedAccessAvailable else {
            lastErrorMessage = "Lid delay skipped because privileged setup is not enabled."
            return
        }

        if !lidOverrideEngaged {
            guard privilegedPowerController.setSleepDisabled(true) else {
                lastErrorMessage = "Failed to enable temporary lid sleep delay (pmset disablesleep=1)."
                return
            }
            lidOverrideEngaged = true
            persistState()
        }

        let candidateEndDate = nowProvider().addingTimeInterval(delaySeconds)
        if let currentEndDate = lidDelayReleaseDate {
            lidDelayReleaseDate = max(currentEndDate, candidateEndDate)
        } else {
            lidDelayReleaseDate = candidateEndDate
        }
    }

    private func handleLidOpened() {
        endLidDelay(triggerSleepIfStillClosed: false)
    }

    private func handleLidDelayIfNeeded() {
        guard let endDate = lidDelayReleaseDate else { return }
        guard nowProvider() >= endDate else { return }
        endLidDelay(triggerSleepIfStillClosed: true)
    }

    private func endLidDelay(triggerSleepIfStillClosed: Bool) {
        lidDelayReleaseDate = nil

        guard lidOverrideEngaged else { return }

        if privilegedPowerController.setSleepDisabled(false) {
            lidOverrideEngaged = false
            persistState()

            if triggerSleepIfStillClosed, lidMonitor.isLidCurrentlyClosed {
                _ = privilegedPowerController.triggerImmediateSleep()
            }
        } else {
            lastErrorMessage = "Failed to restore pmset disablesleep=0 after lid delay."
        }
    }

    private func effectiveLidDelaySeconds() -> TimeInterval {
        var durations: [TimeInterval] = []

        if globalSettings.globalLidDelayEnabled {
            durations.append(max(globalSettings.globalLidDelaySeconds, 0))
        }

        let ruleDurations = rules.compactMap { rule -> TimeInterval? in
            guard rule.enabled else { return nil }
            guard matchedRuleIDs.contains(rule.id) else { return nil }
            return max(rule.lidDelaySeconds, 0)
        }

        durations.append(contentsOf: ruleDurations)
        return durations.max() ?? 0
    }

    private func recoverLidOverrideIfNeeded() {
        guard lidOverrideEngaged else { return }
        guard privilegedAccessAvailable else {
            lastErrorMessage = "Detected previous lid override but privileged access is unavailable; manual reset may be required."
            return
        }

        if privilegedPowerController.setSleepDisabled(false) {
            lidOverrideEngaged = false
            persistState()
        } else {
            lastErrorMessage = "Detected previous lid override but failed to restore pmset disablesleep=0."
        }
    }

    // MARK: - Persistence

    private func persistState() {
        let state = PersistedState(
            globalSettings: globalSettings,
            rules: rules,
            lidOverrideActive: lidOverrideEngaged
        )
        ruleStore.saveState(state)
    }

    private func updatePrivilegedStatus(hasAccess: Bool) {
        privilegedAccessAvailable = hasAccess
        privilegedStatusMessage = hasAccess
            ? "Privileged lid-delay access is enabled."
            : "Privileged lid-delay access is not enabled."
    }

    private func updateScreenRecordingStatus(isGranted: Bool) {
        let newMessage = isGranted
            ? "Screen Recording access is enabled for window-title matching."
            : "Screen Recording access is required to read other apps' window titles."

        if screenRecordingAccessAvailable != isGranted {
            screenRecordingAccessAvailable = isGranted
        }

        if screenRecordingStatusMessage != newMessage {
            screenRecordingStatusMessage = newMessage
        }
    }

    // MARK: - Matching

    private func evaluateRuleMatches(
        rules: [SleepRule],
        processes: [ProcessSnapshot],
        windows: [WindowSnapshot]
    ) -> RuleMatchEvaluation {
        var matchedRuleIDs: Set<UUID> = []
        var ruleMatchDetails: [UUID: [RuleMatchDetail]] = [:]

        let windowsByPID = Dictionary(grouping: windows, by: \.pid)
        let processByPID = processes.reduce(into: [Int32: ProcessSnapshot]()) { result, process in
            for pid in process.pids {
                result[pid] = process
            }
        }

        for rule in rules {
            let ruleValue = normalizeMatchValue(rule.matchValue)
            guard !ruleValue.isEmpty else { continue }

            switch rule.matchMode {
            case .executablePath:
                let matchingProcesses = processes.filter { normalizeMatchValue($0.executablePath) == ruleValue }
                guard !matchingProcesses.isEmpty else { continue }
                matchedRuleIDs.insert(rule.id)

                let details = matchingProcesses.flatMap { process in
                    buildMatchDetails(
                        forPIDs: process.pids,
                        executablePath: process.executablePath,
                        windowsByPID: windowsByPID
                    )
                }
                if !details.isEmpty {
                    ruleMatchDetails[rule.id] = sortAndDeduplicate(details)
                }

            case .processName:
                let matchingProcesses = processes.filter {
                    $0.processName.caseInsensitiveCompare(rule.matchValue) == .orderedSame
                }
                guard !matchingProcesses.isEmpty else { continue }
                matchedRuleIDs.insert(rule.id)

                let details = matchingProcesses.flatMap { process in
                    buildMatchDetails(
                        forPIDs: process.pids,
                        executablePath: process.executablePath,
                        windowsByPID: windowsByPID
                    )
                }
                if !details.isEmpty {
                    ruleMatchDetails[rule.id] = sortAndDeduplicate(details)
                }

            case .windowTitle:
                let matchedWindows = matchingWindows(for: rule, windows: windows)
                guard !matchedWindows.isEmpty else { continue }
                matchedRuleIDs.insert(rule.id)

                let details = matchedWindows.map { window in
                    RuleMatchDetail(
                        pid: window.pid,
                        executablePath: executablePathForRuleMatchDetail(pid: window.pid, processByPID: processByPID),
                        windowTitle: window.title
                    )
                }
                ruleMatchDetails[rule.id] = sortAndDeduplicate(details)
            }
        }

        return RuleMatchEvaluation(matchedRuleIDs: matchedRuleIDs, ruleMatchDetails: ruleMatchDetails)
    }

    private func buildMatchDetails(
        forPIDs pids: [Int32],
        executablePath: String,
        windowsByPID: [Int32: [WindowSnapshot]]
    ) -> [RuleMatchDetail] {
        pids.flatMap { pid in
            let windows = windowsByPID[pid] ?? []
            if windows.isEmpty {
                return [RuleMatchDetail(pid: pid, executablePath: executablePath, windowTitle: nil)]
            }
            return windows.map { window in
                RuleMatchDetail(pid: pid, executablePath: executablePath, windowTitle: window.title)
            }
        }
    }

    private func executablePathForRuleMatchDetail(pid: Int32, processByPID: [Int32: ProcessSnapshot]) -> String {
        if let path = processByPID[pid]?.executablePath {
            return path
        }

        if let path = executablePathForPIDProvider(pid), !path.isEmpty {
            return path
        }

        return "(unknown executable path)"
    }

    private func sortAndDeduplicate(_ details: [RuleMatchDetail]) -> [RuleMatchDetail] {
        let unique = Set(details)
        return unique.sorted { lhs, rhs in
            if lhs.pid != rhs.pid {
                return lhs.pid < rhs.pid
            }
            if lhs.executablePath != rhs.executablePath {
                return lhs.executablePath.localizedCaseInsensitiveCompare(rhs.executablePath) == .orderedAscending
            }
            let leftTitle = lhs.windowTitle ?? ""
            let rightTitle = rhs.windowTitle ?? ""
            return leftTitle.localizedCaseInsensitiveCompare(rightTitle) == .orderedAscending
        }
    }

    private func matchingWindows(for rule: SleepRule, windows: [WindowSnapshot]) -> [WindowSnapshot] {
        let operatorToUse = rule.titleOperator ?? .contains
        let matchValue = rule.matchValue

        switch operatorToUse {
        case .contains:
            let needle = matchValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return [] }
            return windows.filter {
                $0.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }

        case .exact:
            let expected = matchValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expected.isEmpty else { return [] }
            return windows.filter {
                $0.title.compare(expected, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }

        case .regex:
            guard !matchValue.isEmpty else { return [] }
            guard let regex = try? NSRegularExpression(pattern: matchValue, options: [.caseInsensitive]) else {
                return []
            }
            return windows.filter { snapshot in
                let range = NSRange(location: 0, length: snapshot.title.utf16.count)
                return regex.firstMatch(in: snapshot.title, options: [], range: range) != nil
            }
        }
    }

    private func normalizeMatchValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        return trimmed
    }

    private static func defaultExecutablePathForPID(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }

        var pathBuffer = Array<CChar>(repeating: 0, count: Int(4 * MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }

        let utf8PathBytes = pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let rawPath = String(decoding: utf8PathBytes, as: UTF8.self)
        guard !rawPath.isEmpty else { return nil }

        return URL(fileURLWithPath: rawPath).standardizedFileURL.path
    }
}

protocol CPUUsageSampling {
    func sampleCPUUsage(forPIDs pids: Set<Int32>) -> CPUUsageSnapshot
}

struct CPUUsageSnapshot {
    let systemPercent: Double?
    let pidPercentages: [Int32: Double]
}

private struct CPUSample {
    let timestamp: Date
    let percent: Double
}

final class SystemCPUSampler: CPUUsageSampling {
    private let processorCount: Double

    private var previousSystemTicks: [UInt32]?
    private var previousTimestamp: Date?
    private var previousCPUTimeByPID: [Int32: UInt64] = [:]

    init(processorCount: Int = ProcessInfo.processInfo.processorCount) {
        self.processorCount = max(Double(processorCount), 1)
    }

    func sampleCPUUsage(forPIDs pids: Set<Int32>) -> CPUUsageSnapshot {
        let now = Date()
        let systemPercent = sampleSystemCPUPercent()

        let currentCPUTimeByPID = cpuTimeByPID(for: pids)
        var pidPercentages: [Int32: Double] = [:]

        if let previousTimestamp {
            let elapsedSeconds = now.timeIntervalSince(previousTimestamp)
            if elapsedSeconds > 0 {
                let totalCapacityNanos = elapsedSeconds * 1_000_000_000 * processorCount
                if totalCapacityNanos > 0 {
                    for (pid, currentCPUTimeNanos) in currentCPUTimeByPID {
                        guard let previousCPUTimeNanos = previousCPUTimeByPID[pid] else { continue }
                        guard currentCPUTimeNanos >= previousCPUTimeNanos else { continue }

                        let deltaNanos = Double(currentCPUTimeNanos - previousCPUTimeNanos)
                        pidPercentages[pid] = max((deltaNanos / totalCapacityNanos) * 100, 0)
                    }
                }
            }
        }

        previousCPUTimeByPID = currentCPUTimeByPID
        previousTimestamp = now

        return CPUUsageSnapshot(systemPercent: systemPercent, pidPercentages: pidPercentages)
    }

    private func sampleSystemCPUPercent() -> Double? {
        guard let currentTicks = systemCPUTicks() else { return nil }
        defer { previousSystemTicks = currentTicks }

        guard let previousSystemTicks else { return nil }

        let deltas = zip(currentTicks, previousSystemTicks).map { current, previous -> Double in
            guard current >= previous else { return 0 }
            return Double(current - previous)
        }

        let total = deltas.reduce(0, +)
        guard total > 0 else { return 0 }

        let active = deltas[Int(CPU_STATE_USER)] + deltas[Int(CPU_STATE_SYSTEM)] + deltas[Int(CPU_STATE_NICE)]
        return max(min((active / total) * 100, 100), 0)
    }

    private func systemCPUTicks() -> [UInt32]? {
        var loadInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let status = withUnsafeMutablePointer(to: &loadInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &count)
            }
        }

        guard status == KERN_SUCCESS else { return nil }

        return [
            UInt32(loadInfo.cpu_ticks.0),
            UInt32(loadInfo.cpu_ticks.1),
            UInt32(loadInfo.cpu_ticks.2),
            UInt32(loadInfo.cpu_ticks.3)
        ]
    }

    private func cpuTimeByPID(for pids: Set<Int32>) -> [Int32: UInt64] {
        var totals: [Int32: UInt64] = [:]

        for pid in pids where pid > 0 {
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) { usagePointer in
                usagePointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPointer in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPointer)
                }
            }
            guard status == 0 else { continue }

            totals[pid] = usage.ri_user_time + usage.ri_system_time
        }

        return totals
    }
}
