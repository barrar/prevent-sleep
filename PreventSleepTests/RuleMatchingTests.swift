import XCTest
@testable import PreventSleep

final class RuleMatchingTests: XCTestCase {
    func testRuleMatchingByExecutablePathProcessNameAndWindowTitleOperators() {
        let process = ProcessSnapshot(
            executablePath: "/opt/homebrew/bin/node",
            processName: "node",
            pids: [123]
        )

        let window = WindowSnapshot(pid: 123, ownerName: "Xcode", title: "Build - Xcode")

        let executableRule = SleepRule(label: "Node Path", matchMode: .executablePath, matchValue: "/opt/homebrew/bin/node")
        let processNameRule = SleepRule(label: "Node Name", matchMode: .processName, matchValue: "NODE")
        let containsTitleRule = SleepRule(label: "Window Contains", matchMode: .windowTitle, matchValue: "xcode", titleOperator: .contains)
        let exactTitleRule = SleepRule(label: "Window Exact", matchMode: .windowTitle, matchValue: "build - xcode", titleOperator: .exact)
        let regexTitleRule = SleepRule(label: "Window Regex", matchMode: .windowTitle, matchValue: "Build\\s-\\sXcode", titleOperator: .regex)

        let store = InMemoryRuleStore(state: PersistedState(
            globalSettings: .default,
            rules: [executableRule, processNameRule, containsTitleRule, exactTitleRule, regexTitleRule],
            lidOverrideActive: false
        ))

        let processScanner = MockProcessScanner()
        processScanner.processes = [process]

        let windowScanner = MockWindowScanner()
        windowScanner.windows = [window]

        let appState = AppState(
            sleepController: MockSleepAssertionController(),
            processScanner: processScanner,
            windowScanner: windowScanner,
            lidMonitor: MockLidMonitor(),
            privilegedPowerController: MockPrivilegedPowerController(),
            ruleStore: store,
            loginItemController: MockLoginItemController(),
            autoStartMonitoring: false
        )

        let matchedIDs = appState.matchedRuleIDs
        XCTAssertTrue(matchedIDs.contains(executableRule.id))
        XCTAssertTrue(matchedIDs.contains(processNameRule.id))
        XCTAssertTrue(matchedIDs.contains(containsTitleRule.id))
        XCTAssertTrue(matchedIDs.contains(exactTitleRule.id))
        XCTAssertTrue(matchedIDs.contains(regexTitleRule.id))
    }

    func testPostExitTimerStartsOnUnmatchAndCancelsOnRematch() {
        let trackedRule = SleepRule(
            label: "Node",
            matchMode: .executablePath,
            matchValue: "/opt/homebrew/bin/node",
            keepAwakeAfterExitSeconds: 120
        )

        let store = InMemoryRuleStore(state: PersistedState(
            globalSettings: .default,
            rules: [trackedRule],
            lidOverrideActive: false
        ))

        let processScanner = MockProcessScanner()
        processScanner.processes = [
            ProcessSnapshot(executablePath: "/opt/homebrew/bin/node", processName: "node", pids: [42])
        ]

        let appState = AppState(
            sleepController: MockSleepAssertionController(),
            processScanner: processScanner,
            windowScanner: MockWindowScanner(),
            lidMonitor: MockLidMonitor(),
            privilegedPowerController: MockPrivilegedPowerController(),
            ruleStore: store,
            loginItemController: MockLoginItemController(),
            autoStartMonitoring: false
        )

        XCTAssertTrue(appState.matchedRuleIDs.contains(trackedRule.id))
        XCTAssertNil(appState.postExitTimerEndDates[trackedRule.id])

        processScanner.processes = []
        appState.refreshNow()

        XCTAssertFalse(appState.matchedRuleIDs.contains(trackedRule.id))
        XCTAssertNotNil(appState.postExitTimerEndDates[trackedRule.id])
        XCTAssertTrue(appState.isSleepCurrentlyPrevented)

        processScanner.processes = [
            ProcessSnapshot(executablePath: "/opt/homebrew/bin/node", processName: "node", pids: [42])
        ]
        appState.refreshNow()

        XCTAssertTrue(appState.matchedRuleIDs.contains(trackedRule.id))
        XCTAssertNil(appState.postExitTimerEndDates[trackedRule.id])
    }

    func testEnabledRuleListKeepsInactiveRulesAndMenuDisableHidesEnabledEntryOnly() {
        let rule = SleepRule(
            enabled: true,
            label: "Inactive Enabled Rule",
            matchMode: .processName,
            matchValue: "SomeProcess"
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

        XCTAssertEqual(appState.enabledRules.count, 1)
        XCTAssertFalse(appState.isRuleCurrentlyMatched(rule.id))

        appState.disableEnabledRuleFromMenu(rule.id)

        XCTAssertTrue(appState.rules.contains(where: { $0.id == rule.id && $0.enabled == false }))
        XCTAssertEqual(appState.enabledRules.count, 0)
        XCTAssertEqual(store.persistedState.rules.first?.enabled, false)
    }

    func testLegacyRuleDecodingDefaultsCPUThresholdFields() throws {
        let legacyJSON = """
        {
          "id": "A06114A4-2A78-4D90-8570-C76F24731EFC",
          "enabled": true,
          "label": "Legacy Rule",
          "matchMode": "processName",
          "matchValue": "node",
          "titleOperator": null,
          "preventWhileMatched": true,
          "keepAwakeAfterExitSeconds": 0,
          "lidDelaySeconds": 0
        }
        """

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SleepRule.self, from: Data(legacyJSON.utf8))

        XCTAssertFalse(decoded.allowSleepWhenCPUPeakDropsBelowThreshold)
        XCTAssertEqual(decoded.cpuUsageThresholdPercent, 2, accuracy: 0.0001)
    }

    func testProcessRuleMatchDetailsIncludeAllMatchedPIDsAndWindows() {
        let rule = SleepRule(
            label: "Node Name",
            matchMode: .processName,
            matchValue: "node"
        )

        let store = InMemoryRuleStore(state: PersistedState(
            globalSettings: .default,
            rules: [rule],
            lidOverrideActive: false
        ))

        let processScanner = MockProcessScanner()
        processScanner.processes = [
            ProcessSnapshot(executablePath: "/opt/homebrew/bin/node", processName: "node", pids: [101, 102]),
            ProcessSnapshot(executablePath: "/usr/local/bin/node", processName: "node", pids: [201])
        ]

        let windowScanner = MockWindowScanner()
        windowScanner.windows = [
            WindowSnapshot(pid: 101, ownerName: "Node", title: "Worker A"),
            WindowSnapshot(pid: 101, ownerName: "Node", title: "Worker B"),
            WindowSnapshot(pid: 201, ownerName: "Node", title: "Coordinator")
        ]

        let appState = AppState(
            sleepController: MockSleepAssertionController(),
            processScanner: processScanner,
            windowScanner: windowScanner,
            cpuSampler: MockCPUSampler(),
            lidMonitor: MockLidMonitor(),
            privilegedPowerController: MockPrivilegedPowerController(),
            ruleStore: store,
            loginItemController: MockLoginItemController(),
            autoStartMonitoring: false
        )

        let details = appState.ruleMatchDetails(for: rule.id)

        XCTAssertEqual(details.count, 4)
        XCTAssertTrue(details.contains(RuleMatchDetail(pid: 101, executablePath: "/opt/homebrew/bin/node", windowTitle: "Worker A")))
        XCTAssertTrue(details.contains(RuleMatchDetail(pid: 101, executablePath: "/opt/homebrew/bin/node", windowTitle: "Worker B")))
        XCTAssertTrue(details.contains(RuleMatchDetail(pid: 102, executablePath: "/opt/homebrew/bin/node", windowTitle: nil)))
        XCTAssertTrue(details.contains(RuleMatchDetail(pid: 201, executablePath: "/usr/local/bin/node", windowTitle: "Coordinator")))
    }

    func testWindowTitleRuleMatchDetailsIncludeAllMatchedWindows() {
        let rule = SleepRule(
            label: "Build Windows",
            matchMode: .windowTitle,
            matchValue: "build",
            titleOperator: .contains
        )

        let store = InMemoryRuleStore(state: PersistedState(
            globalSettings: .default,
            rules: [rule],
            lidOverrideActive: false
        ))

        let processScanner = MockProcessScanner()
        processScanner.processes = [
            ProcessSnapshot(executablePath: "/Applications/Xcode.app/Contents/MacOS/Xcode", processName: "Xcode", pids: [10, 11])
        ]

        let windowScanner = MockWindowScanner()
        windowScanner.windows = [
            WindowSnapshot(pid: 10, ownerName: "Xcode", title: "Build - Debug"),
            WindowSnapshot(pid: 11, ownerName: "Xcode", title: "Build - Release"),
            WindowSnapshot(pid: 10, ownerName: "Xcode", title: "Navigator")
        ]

        let appState = AppState(
            sleepController: MockSleepAssertionController(),
            processScanner: processScanner,
            windowScanner: windowScanner,
            cpuSampler: MockCPUSampler(),
            lidMonitor: MockLidMonitor(),
            privilegedPowerController: MockPrivilegedPowerController(),
            ruleStore: store,
            loginItemController: MockLoginItemController(),
            autoStartMonitoring: false
        )

        let details = appState.ruleMatchDetails(for: rule.id)

        XCTAssertEqual(details.count, 2)
        XCTAssertTrue(details.contains(RuleMatchDetail(
            pid: 10,
            executablePath: "/Applications/Xcode.app/Contents/MacOS/Xcode",
            windowTitle: "Build - Debug"
        )))
        XCTAssertTrue(details.contains(RuleMatchDetail(
            pid: 11,
            executablePath: "/Applications/Xcode.app/Contents/MacOS/Xcode",
            windowTitle: "Build - Release"
        )))
    }

    func testWindowTitleRuleMatchDetailsResolvePathFromPIDFallbackWhenProcessSnapshotIsMissing() {
        let rule = SleepRule(
            label: "Build Windows",
            matchMode: .windowTitle,
            matchValue: "build",
            titleOperator: .contains
        )

        let store = InMemoryRuleStore(state: PersistedState(
            globalSettings: .default,
            rules: [rule],
            lidOverrideActive: false
        ))

        let windowScanner = MockWindowScanner()
        windowScanner.windows = [
            WindowSnapshot(pid: 6928, ownerName: "SomeApp", title: "Build - Detached")
        ]

        let appState = AppState(
            sleepController: MockSleepAssertionController(),
            processScanner: MockProcessScanner(),
            windowScanner: windowScanner,
            cpuSampler: MockCPUSampler(),
            lidMonitor: MockLidMonitor(),
            privilegedPowerController: MockPrivilegedPowerController(),
            ruleStore: store,
            loginItemController: MockLoginItemController(),
            executablePathForPIDProvider: { pid in
                guard pid == 6928 else { return nil }
                return "/Applications/SomeApp.app/Contents/MacOS/SomeApp"
            },
            autoStartMonitoring: false
        )

        let details = appState.ruleMatchDetails(for: rule.id)

        XCTAssertEqual(details.count, 1)
        XCTAssertEqual(details.first?.pid, 6928)
        XCTAssertEqual(details.first?.windowTitle, "Build - Detached")
        XCTAssertEqual(details.first?.executablePath, "/Applications/SomeApp.app/Contents/MacOS/SomeApp")
    }
}
