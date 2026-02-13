import Foundation

enum MatchMode: String, Codable, CaseIterable, Identifiable {
    case executablePath
    case processName
    case windowTitle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .executablePath: return "Executable Path"
        case .processName: return "Process Name"
        case .windowTitle: return "Window Title"
        }
    }
}

enum WindowTitleOperator: String, Codable, CaseIterable, Identifiable {
    case contains
    case exact
    case regex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contains: return "Contains"
        case .exact: return "Exact"
        case .regex: return "Regex"
        }
    }
}

enum SleepMode: String, Codable, CaseIterable, Identifiable {
    case systemOnly
    case systemAndDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemOnly: return "Prevent System Sleep Only"
        case .systemAndDisplay: return "Prevent System + Display Sleep"
        }
    }
}

struct SleepRule: Identifiable, Codable, Hashable {
    var id: UUID
    var enabled: Bool
    var label: String
    var matchMode: MatchMode
    var matchValue: String
    var titleOperator: WindowTitleOperator?
    var preventWhileMatched: Bool
    var allowSleepWhenCPUPeakDropsBelowThreshold: Bool
    var cpuUsageThresholdPercent: Double
    var keepAwakeAfterExitSeconds: TimeInterval
    var lidDelaySeconds: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case id
        case enabled
        case label
        case matchMode
        case matchValue
        case titleOperator
        case preventWhileMatched
        case allowSleepWhenCPUPeakDropsBelowThreshold
        case cpuUsageThresholdPercent
        case keepAwakeAfterExitSeconds
        case lidDelaySeconds
    }

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        label: String,
        matchMode: MatchMode,
        matchValue: String,
        titleOperator: WindowTitleOperator? = nil,
        preventWhileMatched: Bool = true,
        allowSleepWhenCPUPeakDropsBelowThreshold: Bool = false,
        cpuUsageThresholdPercent: Double = 2,
        keepAwakeAfterExitSeconds: TimeInterval = 0,
        lidDelaySeconds: TimeInterval = 0
    ) {
        self.id = id
        self.enabled = enabled
        self.label = label
        self.matchMode = matchMode
        self.matchValue = matchValue
        self.titleOperator = titleOperator
        self.preventWhileMatched = preventWhileMatched
        self.allowSleepWhenCPUPeakDropsBelowThreshold = allowSleepWhenCPUPeakDropsBelowThreshold
        self.cpuUsageThresholdPercent = max(cpuUsageThresholdPercent, 0)
        self.keepAwakeAfterExitSeconds = keepAwakeAfterExitSeconds
        self.lidDelaySeconds = lidDelaySeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        label = try container.decode(String.self, forKey: .label)
        matchMode = try container.decode(MatchMode.self, forKey: .matchMode)
        matchValue = try container.decode(String.self, forKey: .matchValue)
        titleOperator = try container.decodeIfPresent(WindowTitleOperator.self, forKey: .titleOperator)
        preventWhileMatched = try container.decode(Bool.self, forKey: .preventWhileMatched)
        allowSleepWhenCPUPeakDropsBelowThreshold =
            try container.decodeIfPresent(Bool.self, forKey: .allowSleepWhenCPUPeakDropsBelowThreshold) ?? false
        cpuUsageThresholdPercent =
            max(try container.decodeIfPresent(Double.self, forKey: .cpuUsageThresholdPercent) ?? 2, 0)
        keepAwakeAfterExitSeconds = try container.decode(TimeInterval.self, forKey: .keepAwakeAfterExitSeconds)
        lidDelaySeconds = try container.decode(TimeInterval.self, forKey: .lidDelaySeconds)
    }
}

struct GlobalSettings: Codable, Equatable {
    var preventIndefinitely: Bool
    var manualTimerEndDate: Date?
    var globalLidDelayEnabled: Bool
    var globalLidDelaySeconds: TimeInterval
    var allowSleepWhenSystemCPUBelowThreshold: Bool
    var systemCPUUsageThresholdPercent: Double
    var defaultNewRuleMatchMode: MatchMode
    var sleepMode: SleepMode

    private enum CodingKeys: String, CodingKey {
        case preventIndefinitely
        case manualTimerEndDate
        case globalLidDelayEnabled
        case globalLidDelaySeconds
        case allowSleepWhenSystemCPUBelowThreshold
        case systemCPUUsageThresholdPercent
        case defaultNewRuleMatchMode
        case sleepMode
    }

    static let `default` = GlobalSettings(
        preventIndefinitely: false,
        manualTimerEndDate: nil,
        globalLidDelayEnabled: false,
        globalLidDelaySeconds: 0,
        allowSleepWhenSystemCPUBelowThreshold: false,
        systemCPUUsageThresholdPercent: 2,
        defaultNewRuleMatchMode: .executablePath,
        sleepMode: .systemOnly
    )

    init(
        preventIndefinitely: Bool,
        manualTimerEndDate: Date?,
        globalLidDelayEnabled: Bool,
        globalLidDelaySeconds: TimeInterval,
        allowSleepWhenSystemCPUBelowThreshold: Bool,
        systemCPUUsageThresholdPercent: Double,
        defaultNewRuleMatchMode: MatchMode,
        sleepMode: SleepMode
    ) {
        self.preventIndefinitely = preventIndefinitely
        self.manualTimerEndDate = manualTimerEndDate
        self.globalLidDelayEnabled = globalLidDelayEnabled
        self.globalLidDelaySeconds = globalLidDelaySeconds
        self.allowSleepWhenSystemCPUBelowThreshold = allowSleepWhenSystemCPUBelowThreshold
        self.systemCPUUsageThresholdPercent = max(systemCPUUsageThresholdPercent, 0)
        self.defaultNewRuleMatchMode = defaultNewRuleMatchMode
        self.sleepMode = sleepMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preventIndefinitely = try container.decode(Bool.self, forKey: .preventIndefinitely)
        manualTimerEndDate = try container.decodeIfPresent(Date.self, forKey: .manualTimerEndDate)
        globalLidDelayEnabled = try container.decode(Bool.self, forKey: .globalLidDelayEnabled)
        globalLidDelaySeconds = try container.decode(TimeInterval.self, forKey: .globalLidDelaySeconds)
        allowSleepWhenSystemCPUBelowThreshold =
            try container.decodeIfPresent(Bool.self, forKey: .allowSleepWhenSystemCPUBelowThreshold) ?? false
        systemCPUUsageThresholdPercent =
            max(try container.decodeIfPresent(Double.self, forKey: .systemCPUUsageThresholdPercent) ?? 2, 0)
        defaultNewRuleMatchMode = try container.decode(MatchMode.self, forKey: .defaultNewRuleMatchMode)
        sleepMode = try container.decode(SleepMode.self, forKey: .sleepMode)
    }
}

struct PersistedState: Codable {
    var globalSettings: GlobalSettings
    var rules: [SleepRule]
    var lidOverrideActive: Bool

    static let `default` = PersistedState(globalSettings: .default, rules: [], lidOverrideActive: false)
}

struct ProcessSnapshot: Identifiable, Hashable {
    var id: String { executablePath }
    let executablePath: String
    let processName: String
    let pids: [Int32]
}

struct WindowSnapshot: Identifiable, Hashable {
    var id: String { "\(pid)-\(ownerName)-\(title)" }
    let pid: Int32
    let ownerName: String
    let title: String
}

struct RuleMatchDetail: Identifiable, Hashable {
    var id: String { "\(pid)-\(executablePath)-\(windowTitle ?? "")" }
    let pid: Int32
    let executablePath: String
    let windowTitle: String?
}

struct RuleMatchEvaluation {
    let matchedRuleIDs: Set<UUID>
    let ruleMatchDetails: [UUID: [RuleMatchDetail]]
}
