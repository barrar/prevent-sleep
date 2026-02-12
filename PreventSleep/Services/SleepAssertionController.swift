import Foundation
import IOKit.pwr_mgt

protocol SleepAssertionControlling: AnyObject {
    var isActive: Bool { get }
    var currentMode: SleepMode? { get }
    @discardableResult func activate(mode: SleepMode) -> Bool
    func deactivate()
    func update(isNeeded: Bool, mode: SleepMode)
}

final class SleepAssertionController: SleepAssertionControlling {
    private var assertionID: IOPMAssertionID = 0
    private(set) var currentMode: SleepMode?

    var isActive: Bool {
        assertionID != 0
    }

    @discardableResult
    func activate(mode: SleepMode) -> Bool {
        if isActive {
            deactivate()
        }

        let assertionType: CFString
        switch mode {
        case .systemOnly:
            assertionType = kIOPMAssertPreventUserIdleSystemSleep as CFString
        case .systemAndDisplay:
            assertionType = kIOPMAssertPreventUserIdleDisplaySleep as CFString
        }

        var newAssertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "PreventSleep Active" as CFString,
            &newAssertionID
        )

        guard result == kIOReturnSuccess else {
            return false
        }

        assertionID = newAssertionID
        currentMode = mode
        return true
    }

    func deactivate() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        currentMode = nil
    }

    func update(isNeeded: Bool, mode: SleepMode) {
        if isNeeded {
            if isActive, currentMode == mode {
                return
            }
            _ = activate(mode: mode)
        } else {
            deactivate()
        }
    }

    deinit {
        deactivate()
    }
}
