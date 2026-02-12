import Foundation
import IOKit

protocol LidStateMonitoring: AnyObject {
    var onLidClosed: (() -> Void)? { get set }
    var onLidOpened: (() -> Void)? { get set }
    var isLidCurrentlyClosed: Bool { get }
    func start()
    func stop()
}

final class LidStateMonitor: LidStateMonitoring {
    var onLidClosed: (() -> Void)?
    var onLidOpened: (() -> Void)?

    private(set) var isLidCurrentlyClosed: Bool = false

    private let queue = DispatchQueue(label: "preventsleep.lid-monitor")
    private var timer: DispatchSourceTimer?
    private var lastKnownState: Bool?

    func start() {
        guard timer == nil else { return }

        let initialState = readClamshellState()
        lastKnownState = initialState
        isLidCurrentlyClosed = initialState

        let newTimer = DispatchSource.makeTimerSource(queue: queue)
        newTimer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        newTimer.setEventHandler { [weak self] in
            self?.pollState()
        }
        timer = newTimer
        newTimer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func pollState() {
        let current = readClamshellState()
        let previous = lastKnownState
        lastKnownState = current
        isLidCurrentlyClosed = current

        guard let previous else { return }
        guard current != previous else { return }

        if current {
            guard let handler = onLidClosed else { return }
            DispatchQueue.main.async(execute: handler)
        } else {
            guard let handler = onLidOpened else { return }
            DispatchQueue.main.async(execute: handler)
        }
    }

    private func readClamshellState() -> Bool {
        guard let matching = IOServiceMatching("IOPMrootDomain") else {
            return false
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != MACH_PORT_NULL else {
            return false
        }
        defer {
            IOObjectRelease(service)
        }

        guard let property = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return false
        }

        if CFGetTypeID(property) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((property as! CFBoolean))
        }

        if let number = property as? NSNumber {
            return number.boolValue
        }

        return false
    }
}
