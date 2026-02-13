import Foundation
@testable import PreventSleep

final class MockSleepAssertionController: SleepAssertionControlling {
    var isActive: Bool = false
    var currentMode: SleepMode?

    private(set) var activateCalls: [SleepMode] = []
    private(set) var deactivateCallCount = 0
    private(set) var updateCalls: [(Bool, SleepMode)] = []

    @discardableResult
    func activate(mode: SleepMode) -> Bool {
        activateCalls.append(mode)
        isActive = true
        currentMode = mode
        return true
    }

    func deactivate() {
        deactivateCallCount += 1
        isActive = false
        currentMode = nil
    }

    func update(isNeeded: Bool, mode: SleepMode) {
        updateCalls.append((isNeeded, mode))
        if isNeeded {
            isActive = true
            currentMode = mode
        } else {
            isActive = false
            currentMode = nil
        }
    }
}

final class MockProcessScanner: ProcessScanning {
    var processes: [ProcessSnapshot] = []

    func scanUserProcesses() -> [ProcessSnapshot] {
        processes
    }
}

final class MockWindowScanner: WindowScanning {
    var windows: [WindowSnapshot] = []
    var screenRecordingAccessGranted = true
    var requestScreenRecordingAccessResult = true

    func scanVisibleWindows() -> [WindowSnapshot] {
        windows
    }

    func hasScreenRecordingAccess() -> Bool {
        screenRecordingAccessGranted
    }

    func requestScreenRecordingAccess() -> Bool {
        screenRecordingAccessGranted = requestScreenRecordingAccessResult
        return screenRecordingAccessGranted
    }
}

final class MockCPUSampler: CPUUsageSampling {
    var queuedSnapshots: [CPUUsageSnapshot] = []
    var fallbackSnapshot = CPUUsageSnapshot(systemPercent: nil, pidPercentages: [:])

    func sampleCPUUsage(forPIDs pids: Set<Int32>) -> CPUUsageSnapshot {
        if !queuedSnapshots.isEmpty {
            return queuedSnapshots.removeFirst()
        }
        return fallbackSnapshot
    }
}

final class MockLidMonitor: LidStateMonitoring {
    var onLidClosed: (() -> Void)?
    var onLidOpened: (() -> Void)?
    var isLidCurrentlyClosed: Bool = false

    func start() {}
    func stop() {}

    func emitClosed() {
        isLidCurrentlyClosed = true
        onLidClosed?()
    }

    func emitOpened() {
        isLidCurrentlyClosed = false
        onLidOpened?()
    }
}

final class MockPrivilegedPowerController: PrivilegedPowerControlling {
    var hasAccess: Bool = false
    var setSleepDisabledReturnValue: Bool = true
    var triggerSleepNowReturnValue: Bool = true
    var installResult: PrivilegedSetupResult = .success
    var installDelay: TimeInterval = 0
    var grantAccessOnInstallSuccess: Bool = false

    private(set) var setSleepDisabledCalls: [Bool] = []
    private(set) var triggerSleepNowCallCount: Int = 0
    private(set) var installCallCount: Int = 0

    func hasNonInteractiveAccess() -> Bool {
        hasAccess
    }

    func installPrivilegedAccess() -> PrivilegedSetupResult {
        installCallCount += 1
        if installDelay > 0 {
            Thread.sleep(forTimeInterval: installDelay)
        }
        if case .success = installResult, grantAccessOnInstallSuccess {
            hasAccess = true
        }
        return installResult
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        setSleepDisabledCalls.append(disabled)
        return setSleepDisabledReturnValue
    }

    func triggerImmediateSleep() -> Bool {
        triggerSleepNowCallCount += 1
        return triggerSleepNowReturnValue
    }
}

final class InMemoryRuleStore: RuleStoring {
    let fileURL = URL(fileURLWithPath: "/tmp/preventsleep-tests-state.json")
    var persistedState: PersistedState

    init(state: PersistedState = .default) {
        self.persistedState = state
    }

    func loadState() -> PersistedState {
        persistedState
    }

    func saveState(_ state: PersistedState) {
        persistedState = state
    }
}

final class MockLoginItemController: LoginItemControlling {
    var enabled = false
    var shouldThrow = false

    func isEnabled() -> Bool {
        enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if shouldThrow {
            struct MockError: Error {}
            throw MockError()
        }
        self.enabled = enabled
    }
}

final class TestClock {
    private(set) var now: Date

    init(startingAt date: Date) {
        now = date
    }

    func advance(seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}
