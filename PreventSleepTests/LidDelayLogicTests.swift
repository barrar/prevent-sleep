import XCTest
@testable import PreventSleep

final class LidDelayLogicTests: XCTestCase {
    func testLidDelayUsesLongestDurationAndSleepsWhenStillClosedAfterExpiry() {
        let rule = SleepRule(
            label: "Node Lid Rule",
            matchMode: .executablePath,
            matchValue: "/opt/homebrew/bin/node",
            preventWhileMatched: true,
            keepAwakeAfterExitSeconds: 0,
            lidDelaySeconds: 0.4
        )

        var settings = GlobalSettings.default
        settings.globalLidDelayEnabled = true
        settings.globalLidDelaySeconds = 0.2

        let store = InMemoryRuleStore(state: PersistedState(
            globalSettings: settings,
            rules: [rule],
            lidOverrideActive: false
        ))

        let processScanner = MockProcessScanner()
        processScanner.processes = [
            ProcessSnapshot(executablePath: "/opt/homebrew/bin/node", processName: "node", pids: [12])
        ]

        let lidMonitor = MockLidMonitor()
        let privileged = MockPrivilegedPowerController()
        privileged.hasAccess = true

        let appState = AppState(
            sleepController: MockSleepAssertionController(),
            processScanner: processScanner,
            windowScanner: MockWindowScanner(),
            lidMonitor: lidMonitor,
            privilegedPowerController: privileged,
            ruleStore: store,
            loginItemController: MockLoginItemController(),
            autoStartMonitoring: false
        )

        lidMonitor.emitClosed()
        XCTAssertEqual(privileged.setSleepDisabledCalls, [true])

        usleep(300_000)
        appState.refreshNow()
        XCTAssertEqual(privileged.setSleepDisabledCalls, [true])

        usleep(200_000)
        appState.refreshNow()

        XCTAssertEqual(privileged.setSleepDisabledCalls, [true, false])
        XCTAssertEqual(privileged.triggerSleepNowCallCount, 1)
    }

    func testLidOpeningBeforeExpiryCancelsDelayWithoutForcingSleepNow() {
        let rule = SleepRule(
            label: "Rule",
            matchMode: .processName,
            matchValue: "node",
            lidDelaySeconds: 10
        )

        let store = InMemoryRuleStore(state: PersistedState(
            globalSettings: .default,
            rules: [rule],
            lidOverrideActive: false
        ))

        let processScanner = MockProcessScanner()
        processScanner.processes = [
            ProcessSnapshot(executablePath: "/opt/homebrew/bin/node", processName: "node", pids: [99])
        ]

        let lidMonitor = MockLidMonitor()
        let privileged = MockPrivilegedPowerController()
        privileged.hasAccess = true

        let appState = AppState(
            sleepController: MockSleepAssertionController(),
            processScanner: processScanner,
            windowScanner: MockWindowScanner(),
            lidMonitor: lidMonitor,
            privilegedPowerController: privileged,
            ruleStore: store,
            loginItemController: MockLoginItemController(),
            autoStartMonitoring: false
        )

        XCTAssertNotNil(appState)

        lidMonitor.emitClosed()
        lidMonitor.emitOpened()

        XCTAssertEqual(privileged.setSleepDisabledCalls, [true, false])
        XCTAssertEqual(privileged.triggerSleepNowCallCount, 0)
    }

    func testLaunchRecoveryRestoresSleepDisabledFlagFromPreviousCrashMarker() {
        let store = InMemoryRuleStore(state: PersistedState(
            globalSettings: .default,
            rules: [],
            lidOverrideActive: true
        ))

        let privileged = MockPrivilegedPowerController()
        privileged.hasAccess = true

        _ = AppState(
            sleepController: MockSleepAssertionController(),
            processScanner: MockProcessScanner(),
            windowScanner: MockWindowScanner(),
            lidMonitor: MockLidMonitor(),
            privilegedPowerController: privileged,
            ruleStore: store,
            loginItemController: MockLoginItemController(),
            autoStartMonitoring: false
        )

        XCTAssertEqual(privileged.setSleepDisabledCalls.first, false)
        XCTAssertFalse(store.persistedState.lidOverrideActive)
    }
}
