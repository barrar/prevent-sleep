import SwiftUI
import AppKit

struct MenuContentView: View {
    @ObservedObject var appState: AppState
    let openAdvancedSettings: () -> Void
    let openCustomDuration: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Prevent Sleep Indefinitely", isOn: Binding(
                get: { appState.globalSettings.preventIndefinitely },
                set: { appState.setPreventIndefinitely($0) }
            ))

            Menu("Prevent Sleep For...") {
                Button("15 Minutes") { appState.setManualTimer(durationSeconds: 15 * 60) }
                Button("30 Minutes") { appState.setManualTimer(durationSeconds: 30 * 60) }
                Button("1 Hour") { appState.setManualTimer(durationSeconds: 60 * 60) }
                Button("2 Hours") { appState.setManualTimer(durationSeconds: 2 * 60 * 60) }
                Divider()
                Button("Custom Duration...") { openCustomDuration() }
                if appState.manualTimerRemainingSeconds != nil {
                    Divider()
                    Button("Clear Timed Override") { appState.clearManualTimer() }
                }
            }

            if let manualTimer = appState.manualTimerRemainingLabel {
                Text("Manual timer remaining: \(manualTimer)")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Menu("Sleep Mode") {
                ForEach(SleepMode.allCases) { mode in
                    Button {
                        appState.setSleepMode(mode)
                    } label: {
                        if appState.globalSettings.sleepMode == mode {
                            Text("✓ \(mode.title)")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            }

            Divider()

            Text("Running Processes")
                .font(.headline)

            RunningProcessesMenuSection(appState: appState)

            Divider()

            Text("Enabled Rules")
                .font(.headline)

            EnabledRulesMenuSection(appState: appState)

            Divider()

            Button("Advanced Settings...") {
                openAdvancedSettings()
            }

            Toggle("Launch at Login", isOn: Binding(
                get: { appState.launchAtLoginEnabled },
                set: { appState.setLaunchAtLogin($0) }
            ))

            if let error = appState.lastErrorMessage {
                Text(error)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

private struct RunningProcessesMenuSection: View {
    @ObservedObject var appState: AppState

    var body: some View {
        let processes = Array(appState.runningProcesses.prefix(30))

        if processes.isEmpty {
            Text("No running user processes found")
                .foregroundStyle(.secondary)
        }

        ForEach(processes, id: \.id) { process in
            Button {
                appState.toggleRuleForRunningProcess(process)
            } label: {
                let watched = appState.isProcessWatched(process)
                if watched {
                    Text("✓ \(process.processName)")
                } else {
                    Text(process.processName)
                }
            }
        }

        if appState.runningProcesses.count > 30 {
            Text("Showing first 30 processes")
                .foregroundStyle(.secondary)
        }
    }
}

private struct EnabledRulesMenuSection: View {
    @ObservedObject var appState: AppState

    var body: some View {
        let rules: [SleepRule] = appState.enabledRules

        if rules.isEmpty {
            Text("No enabled rules")
                .foregroundStyle(.secondary)
        }

        ForEach(rules, id: \SleepRule.id) { (rule: SleepRule) in
            Button {
                appState.disableEnabledRuleFromMenu(rule.id)
            } label: {
                let matched = appState.isRuleCurrentlyMatched(rule.id)
                Text("✓ \(rule.label)\(suffix(for: rule, matched: matched))")
                    .foregroundStyle(matched ? .primary : .secondary)
            }
        }
    }

    private func suffix(for rule: SleepRule, matched: Bool) -> String {
        if let timer = appState.postExitTimerRemainingLabel(for: rule.id) {
            return " (timer \(timer))"
        }
        if matched {
            return ""
        }
        return " (inactive)"
    }
}

struct CustomDurationView: View {
    @ObservedObject var appState: AppState

    @State private var hours: Int = 0
    @State private var minutes: Int = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Sleep Prevention Duration")
                .font(.headline)

            HStack(spacing: 12) {
                Stepper(value: $hours, in: 0...24) {
                    Text("Hours: \(hours)")
                }
            }

            HStack(spacing: 12) {
                Stepper(value: $minutes, in: 0...59) {
                    Text("Minutes: \(minutes)")
                }
            }

            let totalSeconds = TimeInterval(hours * 3600 + minutes * 60)
            Text("Total: \(DurationFormatter.format(seconds: totalSeconds))")
                .foregroundStyle(.secondary)

            HStack {
                Button("Apply") {
                    appState.setManualTimer(durationSeconds: totalSeconds)
                }
                .disabled(totalSeconds <= 0)

                Button("Clear") {
                    appState.clearManualTimer()
                }

                Spacer()
            }

            Spacer()
        }
        .padding(20)
    }
}
