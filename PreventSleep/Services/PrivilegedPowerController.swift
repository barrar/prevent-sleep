import Foundation

enum PrivilegedSetupResult: Equatable {
    case success
    case cancelled
    case failure(String)
}

protocol PrivilegedPowerControlling {
    func hasNonInteractiveAccess() -> Bool
    func installPrivilegedAccess() -> PrivilegedSetupResult
    func setSleepDisabled(_ disabled: Bool) -> Bool
    func triggerImmediateSleep() -> Bool
}

final class PrivilegedPowerController: PrivilegedPowerControlling {
    func hasNonInteractiveAccess() -> Bool {
        let result = runProcess(
            launchPath: "/usr/bin/sudo",
            arguments: ["-n", "-l", "/usr/bin/pmset"]
        )
        return result.exitCode == 0
    }

    func installPrivilegedAccess() -> PrivilegedSetupResult {
        guard let scriptURL = privilegedSetupScriptURL() else {
            return .failure("Could not locate install_privileged_access.sh in app resources.")
        }

        let username = NSUserName()
        let command = "/bin/sh \(shellQuoted(scriptURL.path)) \(shellQuoted(username))"
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript = "do shell script \"\(escapedCommand)\" with administrator privileges"
        let result = runProcess(
            launchPath: "/usr/bin/osascript",
            arguments: ["-e", appleScript]
        )

        if result.exitCode == 0 {
            return .success
        }

        let combinedOutput = "\(result.stdout)\n\(result.stderr)"
        if combinedOutput.contains("-128") || combinedOutput.localizedCaseInsensitiveContains("User canceled") {
            return .cancelled
        }

        let message = combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(message.isEmpty ? "Failed to install privileged setup." : message)
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        let value = disabled ? "1" : "0"
        let result = runProcess(
            launchPath: "/usr/bin/sudo",
            arguments: ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]
        )
        return result.exitCode == 0
    }

    func triggerImmediateSleep() -> Bool {
        let result = runProcess(
            launchPath: "/usr/bin/sudo",
            arguments: ["-n", "/usr/bin/pmset", "sleepnow"]
        )
        return result.exitCode == 0
    }

    private func privilegedSetupScriptURL() -> URL? {
        if let url = Bundle.main.url(forResource: "install_privileged_access", withExtension: "sh", subdirectory: "Scripts") {
            return url
        }

        if let url = Bundle.main.url(forResource: "install_privileged_access", withExtension: "sh") {
            return url
        }

        let fallback = URL(fileURLWithPath: "/Users/jeremiah/projects/prevent-sleep/PreventSleep/Scripts/install_privileged_access.sh")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    private func runProcess(launchPath: String, arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, "", error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func shellQuoted(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
