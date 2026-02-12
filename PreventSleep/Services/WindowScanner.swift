import Foundation
import CoreGraphics

protocol WindowScanning {
    func scanVisibleWindows() -> [WindowSnapshot]
    func hasScreenRecordingAccess() -> Bool
    func requestScreenRecordingAccess() -> Bool
}

final class WindowScanner: WindowScanning {
    func scanVisibleWindows() -> [WindowSnapshot] {
        guard let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var results: [WindowSnapshot] = []
        var seen: Set<String> = []

        for item in rawList {
            guard let ownerName = item[kCGWindowOwnerName as String] as? String,
                  let ownerPID = item[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID > 0 else {
                continue
            }

            let title = (item[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { continue }

            let key = "\(ownerPID)-\(ownerName)-\(title)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            results.append(WindowSnapshot(pid: ownerPID, ownerName: ownerName, title: title))
        }

        return results
    }

    func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
