import SwiftUI
import AppKit
import OSLog

@main
struct PreventSleepApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var windowCoordinator = WindowCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                appState: appState,
                openAdvancedSettings: { windowCoordinator.showAdvancedSettings(appState: appState) },
                openCustomDuration: { windowCoordinator.showCustomDuration(appState: appState) }
            )
        } label: {
            Image(systemName: appState.isSleepCurrentlyPrevented ? "bolt.circle.fill" : "bolt.slash.circle")
                .accessibilityLabel(appState.isSleepCurrentlyPrevented ? "Sleep prevention active" : "Sleep prevention inactive")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
private final class WindowCoordinator: ObservableObject {
    private let logger = Logger(subsystem: "com.jeremiah.preventsleep", category: "WindowCoordinator")
    private var advancedWindow: NSWindow?
    private var customDurationWindow: NSWindow?

    func showAdvancedSettings(appState: AppState) {
        logger.info("showAdvancedSettings invoked")
        if advancedWindow == nil {
            let view = AdvancedSettingsView(appState: appState)
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.title = "Advanced Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 900), display: false)
            window.center()
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("advanced-settings")
            advancedWindow = window
            logger.info("advanced-settings window created")
        }
        focusWindow(advancedWindow)
    }

    func showCustomDuration(appState: AppState) {
        logger.info("showCustomDuration invoked")
        if customDurationWindow == nil {
            let view = CustomDurationView(appState: appState)
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.title = "Custom Duration"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setFrame(NSRect(x: 0, y: 0, width: 360, height: 220), display: false)
            window.center()
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("custom-duration")
            customDurationWindow = window
            logger.info("custom-duration window created")
        }
        focusWindow(customDurationWindow)
    }

    private func focusWindow(_ window: NSWindow?) {
        guard let window else { return }
        logger.info("Focusing window: \(window.identifier?.rawValue ?? "unknown", privacy: .public)")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
