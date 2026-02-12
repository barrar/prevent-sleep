import Foundation
import ServiceManagement

protocol LoginItemControlling {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool) throws
}

enum LoginItemError: Error, LocalizedError {
    case unsupportedStatus(SMAppService.Status)

    var errorDescription: String? {
        switch self {
        case .unsupportedStatus(let status):
            return "Unsupported launch-at-login status: \(status.rawValue)"
        }
    }
}

final class LoginItemController: LoginItemControlling {
    func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
