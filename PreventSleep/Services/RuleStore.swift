import Foundation

protocol RuleStoring {
    var fileURL: URL { get }
    func loadState() -> PersistedState
    func saveState(_ state: PersistedState)
}

final class RuleStore: RuleStoring {
    let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = appSupport
                .appendingPathComponent("PreventSleep", isDirectory: true)
                .appendingPathComponent("state.json", isDirectory: false)
        }

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadState() -> PersistedState {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .default
        }

        do {
            return try decoder.decode(PersistedState.self, from: data)
        } catch {
            return .default
        }
    }

    func saveState(_ state: PersistedState) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Failed to save PreventSleep state: \(error)")
        }
    }
}
