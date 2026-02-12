import Foundation
import Darwin

protocol ProcessScanning {
    func scanUserProcesses() -> [ProcessSnapshot]
}

final class ProcessScanner: ProcessScanning {
    private let pidPathBufferSize = Int(4 * MAXPATHLEN)
    private let excludedPathPrefixes = [
        "/System/",
        "/usr/libexec/",
        "/usr/sbin/",
        "/sbin/",
        "/Library/Apple/"
    ]

    func scanUserProcesses() -> [ProcessSnapshot] {
        let currentUID = getuid()
        let maxCount = Int(proc_listallpids(nil, 0))
        guard maxCount > 0 else { return [] }

        var pids = Array<pid_t>(repeating: 0, count: maxCount)
        let bufferSize = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let bytesReturned: Int32 = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(UnsafeMutableRawPointer(buffer.baseAddress), bufferSize)
        }

        guard bytesReturned > 0 else { return [] }

        let pidCount = Int(bytesReturned) / MemoryLayout<pid_t>.stride
        var deduped: [String: ProcessSnapshot] = [:]

        for pid in pids.prefix(pidCount) where pid > 0 {
            var bsdInfo = proc_bsdinfo()
            let infoSize = proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                &bsdInfo,
                Int32(MemoryLayout<proc_bsdinfo>.stride)
            )

            guard infoSize == Int32(MemoryLayout<proc_bsdinfo>.stride) else { continue }
            guard bsdInfo.pbi_uid == currentUID else { continue }

            var pathBuffer = Array<CChar>(repeating: 0, count: pidPathBufferSize)
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard pathLength > 0 else { continue }

            let rawPath = String(cString: pathBuffer)
            guard !rawPath.isEmpty else { continue }

            let normalizedPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard shouldInclude(path: normalizedPath) else { continue }

            let processName = URL(fileURLWithPath: normalizedPath).lastPathComponent

            if var existing = deduped[normalizedPath] {
                var mergedPIDs = existing.pids
                mergedPIDs.append(pid)
                deduped[normalizedPath] = ProcessSnapshot(
                    executablePath: existing.executablePath,
                    processName: existing.processName,
                    pids: mergedPIDs.sorted()
                )
            } else {
                deduped[normalizedPath] = ProcessSnapshot(
                    executablePath: normalizedPath,
                    processName: processName,
                    pids: [pid]
                )
            }
        }

        return deduped.values.sorted {
            $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending
        }
    }

    private func shouldInclude(path: String) -> Bool {
        for prefix in excludedPathPrefixes where path.hasPrefix(prefix) {
            return false
        }
        return true
    }
}
