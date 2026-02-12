import XCTest
@testable import PreventSleep

final class AppStateTests: XCTestCase {
    func testGlobalIndefinitePreventionActivatesSleepAssertion() {
        let sleepController = MockSleepAssertionController()

        let appState = AppState(
            sleepController: sleepController,
            processScanner: MockProcessScanner(),
            windowScanner: MockWindowScanner(),
            lidMonitor: MockLidMonitor(),
            privilegedPowerController: MockPrivilegedPowerController(),
            ruleStore: InMemoryRuleStore(),
            loginItemController: MockLoginItemController(),
            autoStartMonitoring: false
        )

        XCTAssertFalse(appState.isSleepCurrentlyPrevented)

        appState.setPreventIndefinitely(true)

        XCTAssertTrue(appState.isSleepCurrentlyPrevented)
        XCTAssertEqual(sleepController.updateCalls.last?.0, true)

        appState.setPreventIndefinitely(false)
        appState.refreshNow()

        XCTAssertFalse(appState.isSleepCurrentlyPrevented)
        XCTAssertEqual(sleepController.updateCalls.last?.0, false)
    }

    func testManualTimerExpirationClearsManualOverride() {
        let appState = AppState(
            sleepController: MockSleepAssertionController(),
            processScanner: MockProcessScanner(),
            windowScanner: MockWindowScanner(),
            lidMonitor: MockLidMonitor(),
            privilegedPowerController: MockPrivilegedPowerController(),
            ruleStore: InMemoryRuleStore(),
            loginItemController: MockLoginItemController(),
            autoStartMonitoring: false
        )

        appState.setManualTimer(durationSeconds: 120)
        XCTAssertNotNil(appState.globalSettings.manualTimerEndDate)
        XCTAssertTrue(appState.isSleepCurrentlyPrevented)

        appState.globalSettings.manualTimerEndDate = Date().addingTimeInterval(-1)
        appState.refreshNow()

        XCTAssertNil(appState.globalSettings.manualTimerEndDate)
        XCTAssertFalse(appState.isSleepCurrentlyPrevented)
    }

    func testLaunchAtLoginToggleUsesController() {
        let loginItemController = MockLoginItemController()

        let appState = AppState(
            sleepController: MockSleepAssertionController(),
            processScanner: MockProcessScanner(),
            windowScanner: MockWindowScanner(),
            lidMonitor: MockLidMonitor(),
            privilegedPowerController: MockPrivilegedPowerController(),
            ruleStore: InMemoryRuleStore(),
            loginItemController: loginItemController,
            autoStartMonitoring: false
        )

        XCTAssertFalse(appState.launchAtLoginEnabled)
        appState.setLaunchAtLogin(true)
        XCTAssertTrue(appState.launchAtLoginEnabled)
        XCTAssertTrue(loginItemController.enabled)
    }

    func testPrivilegedInstallRunsAsynchronouslyAndUpdatesStatus() {
        let privilegedController = MockPrivilegedPowerController()
        privilegedController.hasAccess = false
        privilegedController.installResult = .success
        privilegedController.installDelay = 0.15
        privilegedController.grantAccessOnInstallSuccess = true

        let appState = AppState(
            sleepController: MockSleepAssertionController(),
            processScanner: MockProcessScanner(),
            windowScanner: MockWindowScanner(),
            lidMonitor: MockLidMonitor(),
            privilegedPowerController: privilegedController,
            ruleStore: InMemoryRuleStore(),
            loginItemController: MockLoginItemController(),
            autoStartMonitoring: false
        )

        XCTAssertFalse(appState.privilegedAccessAvailable)
        XCTAssertFalse(appState.privilegedSetupInProgress)

        appState.installPrivilegedAccess()
        XCTAssertTrue(appState.privilegedSetupInProgress)

        let timeout = Date().addingTimeInterval(2.0)
        while appState.privilegedSetupInProgress && Date() < timeout {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(privilegedController.installCallCount, 1)
        XCTAssertFalse(appState.privilegedSetupInProgress)
        XCTAssertTrue(appState.privilegedAccessAvailable)
        XCTAssertEqual(appState.privilegedStatusMessage, "Privileged lid-delay access is enabled.")
        XCTAssertNil(appState.lastErrorMessage)
    }

    func testScreenRecordingStatusRefreshAndRequestUpdateState() {
        let windowScanner = MockWindowScanner()
        windowScanner.screenRecordingAccessGranted = false
        windowScanner.requestScreenRecordingAccessResult = true

        let appState = AppState(
            sleepController: MockSleepAssertionController(),
            processScanner: MockProcessScanner(),
            windowScanner: windowScanner,
            lidMonitor: MockLidMonitor(),
            privilegedPowerController: MockPrivilegedPowerController(),
            ruleStore: InMemoryRuleStore(),
            loginItemController: MockLoginItemController(),
            autoStartMonitoring: false
        )

        XCTAssertFalse(appState.screenRecordingAccessAvailable)
        XCTAssertEqual(
            appState.screenRecordingStatusMessage,
            "Screen Recording access is required to read other apps' window titles."
        )

        appState.requestScreenRecordingAccess()

        XCTAssertTrue(appState.screenRecordingAccessAvailable)
        XCTAssertEqual(
            appState.screenRecordingStatusMessage,
            "Screen Recording access is enabled for window-title matching."
        )
    }

    func testRuleAllowsSleepAfterFiveMinuteCPUPeakFallsBelowThreshold() {
        let clock = TestClock(startingAt: Date(timeIntervalSince1970: 1_700_000_000))
        let cpuSampler = MockCPUSampler()
        cpuSampler.queuedSamples = [12, 1]

        let processScanner = MockProcessScanner()
        processScanner.processes = [
            ProcessSnapshot(executablePath: "/opt/homebrew/bin/node", processName: "node", pids: [42])
        ]

        let rule = SleepRule(
            label: "Node",
            matchMode: .processName,
            matchValue: "node",
            preventWhileMatched: true,
            allowSleepWhenCPUPeakDropsBelowThreshold: true,
            cpuUsageThresholdPercent: 2
        )

        let store = InMemoryRuleStore(state: PersistedState(
            globalSettings: .default,
            rules: [rule],
            lidOverrideActive: false
        ))

        let appState = AppState(
            sleepController: MockSleepAssertionController(),
            processScanner: processScanner,
            windowScanner: MockWindowScanner(),
            cpuSampler: cpuSampler,
            lidMonitor: MockLidMonitor(),
            privilegedPowerController: MockPrivilegedPowerController(),
            ruleStore: store,
            loginItemController: MockLoginItemController(),
            nowProvider: { clock.now },
            autoStartMonitoring: false
        )

        XCTAssertTrue(appState.isSleepCurrentlyPrevented)

        clock.advance(seconds: 301)
        appState.refreshNow()

        XCTAssertFalse(appState.isSleepCurrentlyPrevented)
    }

    func testCurrentOneMinutePeakCPUIsPublishedForRuleEditor() {
        let clock = TestClock(startingAt: Date(timeIntervalSince1970: 1_700_100_000))
        let cpuSampler = MockCPUSampler()
        cpuSampler.queuedSamples = [3, 11, 4]

        let appState = AppState(
            sleepController: MockSleepAssertionController(),
            processScanner: MockProcessScanner(),
            windowScanner: MockWindowScanner(),
            cpuSampler: cpuSampler,
            lidMonitor: MockLidMonitor(),
            privilegedPowerController: MockPrivilegedPowerController(),
            ruleStore: InMemoryRuleStore(),
            loginItemController: MockLoginItemController(),
            nowProvider: { clock.now },
            autoStartMonitoring: false
        )

        XCTAssertEqual(appState.currentPeakCPUUsageLastMinutePercent ?? -1, 3, accuracy: 0.0001)

        clock.advance(seconds: 30)
        appState.refreshNow()
        XCTAssertEqual(appState.currentPeakCPUUsageLastMinutePercent ?? -1, 11, accuracy: 0.0001)

        clock.advance(seconds: 40)
        appState.refreshNow()
        XCTAssertEqual(appState.currentPeakCPUUsageLastMinutePercent ?? -1, 11, accuracy: 0.0001)
    }

    func testDeleteLastRuleRemovesItFromStateAndPersistence() {
        let rule = SleepRule(
            enabled: true,
            label: "Delete Me",
            matchMode: .processName,
            matchValue: "DeleteMe"
        )

        let store = InMemoryRuleStore(state: PersistedState(
            globalSettings: .default,
            rules: [rule],
            lidOverrideActive: false
        ))

        let appState = AppState(
            sleepController: MockSleepAssertionController(),
            processScanner: MockProcessScanner(),
            windowScanner: MockWindowScanner(),
            lidMonitor: MockLidMonitor(),
            privilegedPowerController: MockPrivilegedPowerController(),
            ruleStore: store,
            loginItemController: MockLoginItemController(),
            autoStartMonitoring: false
        )

        XCTAssertEqual(appState.rules.count, 1)
        XCTAssertEqual(appState.enabledRules.count, 1)

        appState.deleteRule(rule.id)

        XCTAssertTrue(appState.rules.isEmpty)
        XCTAssertTrue(appState.enabledRules.isEmpty)
        XCTAssertTrue(store.persistedState.rules.isEmpty)
    }
}
