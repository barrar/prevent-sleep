import SwiftUI
import AppKit

struct AdvancedSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedRuleID: UUID?

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                globalSettingsSection
                Divider()
                rulesSection
            }
            .padding(12)
            .navigationSplitViewColumnWidth(min: 340, ideal: 340, max: 340)
        } detail: {
            if let selectedRule = selectedRuleBinding {
                RuleEditorView(rule: selectedRule, appState: appState)
                    .padding(16)
            } else {
                ContentUnavailableView(
                    "Select a Rule",
                    systemImage: "slider.horizontal.3",
                    description: Text("Select a rule in the sidebar to edit matching and timing behavior.")
                )
            }
        }
        .onAppear {
            if selectedRuleID == nil {
                selectedRuleID = appState.rules.first?.id
            }
            appState.refreshScreenRecordingAccessStatus()
        }
        .onChange(of: appState.rules) { _, newValue in
            if let selectedRuleID, !newValue.contains(where: { $0.id == selectedRuleID }) {
                self.selectedRuleID = newValue.first?.id
            }
        }
    }

    private var globalSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Global Settings")
                .font(.headline)

            Picker("Default New Rule Mode", selection: Binding(
                get: { appState.globalSettings.defaultNewRuleMatchMode },
                set: { appState.setDefaultRuleMatchMode($0) }
            )) {
                ForEach(MatchMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Picker("Sleep Mode", selection: Binding(
                get: { appState.globalSettings.sleepMode },
                set: { appState.setSleepMode($0) }
            )) {
                ForEach(SleepMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Toggle("Allow Sleep When 5-Min Peak System CPU Drops Below Threshold", isOn: Binding(
                get: { appState.globalSettings.allowSleepWhenSystemCPUBelowThreshold },
                set: {
                    appState.setGlobalCPUAllowance(
                        enabled: $0,
                        thresholdPercent: appState.globalSettings.systemCPUUsageThresholdPercent
                    )
                }
            ))

            VStack(alignment: .leading, spacing: 6) {
                Stepper(value: globalCPUThresholdBinding, in: 0...100, step: 2) {
                    Text("System CPU Threshold: \(appState.globalSettings.systemCPUUsageThresholdPercent, specifier: "%.0f")%")
                }
                Text("Current 1-Min Peak System CPU: \(oneMinuteSystemPeakLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!appState.globalSettings.allowSleepWhenSystemCPUBelowThreshold)

            Toggle("Enable Global Lid-Close Delay", isOn: Binding(
                get: { appState.globalSettings.globalLidDelayEnabled },
                set: { appState.setGlobalLidDelay(enabled: $0, seconds: appState.globalSettings.globalLidDelaySeconds) }
            ))

            DurationEditor(
                title: "Global Lid Delay",
                seconds: Binding(
                    get: { appState.globalSettings.globalLidDelaySeconds },
                    set: { appState.setGlobalLidDelay(enabled: appState.globalSettings.globalLidDelayEnabled, seconds: $0) }
                )
            )
            .disabled(!appState.globalSettings.globalLidDelayEnabled)

            Divider()

            Text("Privileged Lid Delay Access")
                .font(.headline)

            Text(appState.privilegedStatusMessage)
                .foregroundStyle(appState.privilegedAccessAvailable ? .green : .secondary)

            HStack {
                Button(appState.privilegedSetupInProgress ? "Enabling..." : "Enable Privileged Access") {
                    appState.installPrivilegedAccess()
                }
                .disabled(appState.privilegedSetupInProgress)

                Button("Refresh Status") {
                    appState.refreshPrivilegedAccessStatus()
                }
                .disabled(appState.privilegedSetupInProgress)

                if appState.privilegedSetupInProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Divider()

            Text("Window Title Access")
                .font(.headline)

            Text(appState.screenRecordingStatusMessage)
                .foregroundStyle(appState.screenRecordingAccessAvailable ? .green : .secondary)

            HStack {
                Button("Request Access") {
                    appState.requestScreenRecordingAccess()
                }

                Button("Open System Settings") {
                    openScreenRecordingSettings()
                }

                Button("Refresh Status") {
                    appState.refreshScreenRecordingAccessStatus()
                }
            }

            if !appState.screenRecordingAccessAvailable {
                Text("Enable PreventSleep in Privacy & Security > Screen Recording, then relaunch the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = appState.lastErrorMessage {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rules")
                    .font(.headline)
                Spacer()
                Button("Add Rule") {
                    appState.addRule()
                    selectedRuleID = appState.rules.last?.id
                }
            }

            List(selection: $selectedRuleID) {
                ForEach(appState.rules) { rule in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.label.isEmpty ? "(Unnamed Rule)" : rule.label)
                        Text(ruleSummary(rule))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(rule.id)
                }
            }

            HStack {
                Button("Duplicate") {
                    guard let selectedRuleID else { return }
                    appState.duplicateRule(selectedRuleID)
                    self.selectedRuleID = appState.rules.last?.id
                }
                .disabled(selectedRuleID == nil)

                Button("Delete") {
                    guard let selectedRuleID else { return }
                    let remainingRules = appState.rules.filter { $0.id != selectedRuleID }
                    self.selectedRuleID = remainingRules.first?.id
                    appState.deleteRule(selectedRuleID)
                }
                .disabled(selectedRuleID == nil)
            }
        }
    }

    private func ruleSummary(_ rule: SleepRule) -> String {
        let status = rule.enabled ? "Enabled" : "Disabled"
        return "\(status) • \(rule.matchMode.title)"
    }

    private var selectedRuleBinding: Binding<SleepRule>? {
        guard let selectedRuleID,
              let selectedRule = appState.rules.first(where: { $0.id == selectedRuleID }) else {
            return nil
        }

        return Binding(
            get: {
                appState.rules.first(where: { $0.id == selectedRuleID }) ?? selectedRule
            },
            set: { updatedRule in
                guard let index = appState.rules.firstIndex(where: { $0.id == selectedRuleID }) else { return }
                appState.rules[index] = updatedRule
            }
        )
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private var globalCPUThresholdBinding: Binding<Double> {
        Binding(
            get: { appState.globalSettings.systemCPUUsageThresholdPercent },
            set: { newValue in
                appState.setGlobalCPUAllowance(
                    enabled: appState.globalSettings.allowSleepWhenSystemCPUBelowThreshold,
                    thresholdPercent: max(newValue, 0)
                )
            }
        )
    }

    private var oneMinuteSystemPeakLabel: String {
        guard let value = appState.currentSystemPeakCPUUsageLastMinutePercent else {
            return "Collecting samples..."
        }
        return String(format: "%.1f%%", value)
    }
}

private struct RuleEditorView: View {
    @Binding var rule: SleepRule
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("Rule") {
                Toggle("Enabled", isOn: $rule.enabled)
                TextField("Label", text: $rule.label)

                Picker("Match Mode", selection: $rule.matchMode) {
                    ForEach(MatchMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                TextField(matchValuePlaceholder, text: $rule.matchValue)

                if rule.matchMode == .windowTitle {
                    Picker("Window Title Operator", selection: Binding(
                        get: { rule.titleOperator ?? .contains },
                        set: { rule.titleOperator = $0 }
                    )) {
                        ForEach(WindowTitleOperator.allCases) { op in
                            Text(op.title).tag(op)
                        }
                    }

                    if !appState.screenRecordingAccessAvailable {
                        Text("Window-title matching requires Screen Recording access.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Actions") {
                Toggle("Prevent Sleep While Matched", isOn: $rule.preventWhileMatched)
                Toggle(
                    "Allow Sleep When 5-Min Peak CPU Drops Below Threshold",
                    isOn: $rule.allowSleepWhenCPUPeakDropsBelowThreshold
                )
                VStack(alignment: .leading, spacing: 6) {
                    Stepper(value: cpuThresholdBinding, in: 0...100, step: 2) {
                        Text("CPU Threshold: \(rule.cpuUsageThresholdPercent, specifier: "%.0f")%")
                    }
                    Text("Current 1-Min Peak CPU (Matched PIDs Total): \(oneMinutePeakLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!rule.allowSleepWhenCPUPeakDropsBelowThreshold)
                DurationEditor(title: "Keep Awake After Match Ends", seconds: $rule.keepAwakeAfterExitSeconds)
                DurationEditor(title: "Lid Delay While Matched", seconds: $rule.lidDelaySeconds)
            }

            Section("Current Matches") {
                let details = appState.ruleMatchDetails(for: rule.id)
                if details.isEmpty {
                    Text("No active matches.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(details) { detail in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PID: \(detail.pid)")
                            Text("Path: \(detail.executablePath)")
                                .font(.caption)
                                .textSelection(.enabled)
                            Text("Window: \(detail.windowTitle ?? "(no visible window title)")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var matchValuePlaceholder: String {
        switch rule.matchMode {
        case .executablePath:
            return "Executable path (e.g. /Applications/Xcode.app/Contents/MacOS/Xcode)"
        case .processName:
            return "Process name (e.g. Xcode)"
        case .windowTitle:
            return "Window title match text"
        }
    }

    private var cpuThresholdBinding: Binding<Double> {
        Binding(
            get: { rule.cpuUsageThresholdPercent },
            set: { rule.cpuUsageThresholdPercent = max($0, 0) }
        )
    }

    private var oneMinutePeakLabel: String {
        guard let value = appState.rulePeakCPUUsageLastMinutePercent(for: rule.id) else {
            return "Collecting samples..."
        }
        return String(format: "%.1f%%", value)
    }
}

private struct DurationEditor: View {
    let title: String
    @Binding var seconds: TimeInterval
    private let hourRange = 0...72
    private let minuteRange = 0...59

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            HourMinuteInputView(
                hourRange: hourRange,
                minuteRange: minuteRange,
                hours: hoursBinding,
                minutes: minutesBinding
            )
        }
    }

    private var hoursBinding: Binding<Int> {
        Binding(
            get: {
                Int(max(seconds, 0)) / 3600
            },
            set: { newHours in
                let clampedHours = min(max(newHours, hourRange.lowerBound), hourRange.upperBound)
                let minutes = Int(max(seconds, 0)) % 3600 / 60
                seconds = TimeInterval(clampedHours * 3600 + max(0, minutes) * 60)
            }
        )
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: {
                Int(max(seconds, 0)) % 3600 / 60
            },
            set: { newMinutes in
                let clampedMinutes = min(max(newMinutes, minuteRange.lowerBound), minuteRange.upperBound)
                let hours = Int(max(seconds, 0)) / 3600
                let clampedHours = min(max(hours, hourRange.lowerBound), hourRange.upperBound)
                seconds = TimeInterval(clampedHours * 3600 + clampedMinutes * 60)
            }
        )
    }
}
