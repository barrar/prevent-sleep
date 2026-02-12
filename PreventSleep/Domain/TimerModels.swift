import Foundation

struct DurationParts: Equatable {
    var hours: Int
    var minutes: Int

    var totalSeconds: TimeInterval {
        TimeInterval((max(0, hours) * 3600) + (max(0, minutes) * 60))
    }
}

enum DurationFormatter {
    static func format(seconds: TimeInterval) -> String {
        let value = max(Int(seconds.rounded()), 0)
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let secs = value % 60

        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, secs)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, secs)
        }
        return "\(secs)s"
    }
}
