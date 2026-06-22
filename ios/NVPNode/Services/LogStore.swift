import Foundation

enum LogLevel: String {
    case info, success, warn, error
}

struct LogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let level: LogLevel
    let message: String
}

/// In-memory ring buffer of worker activity, shown in the Logs console.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()
    @Published private(set) var entries: [LogEntry] = []
    private let maxEntries = 400

    func add(_ level: LogLevel, _ message: String) {
        entries.append(LogEntry(time: Date(), level: level, message: message))
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
    }

    func clear() { entries.removeAll() }

    /// Plain-text dump for sharing/copying.
    var text: String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return entries
            .map { "\(df.string(from: $0.time)) [\($0.level.rawValue.uppercased())] \($0.message)" }
            .joined(separator: "\n")
    }
}

/// Thread-safe logging from anywhere (hops to the main actor).
nonisolated func nvpLog(_ level: LogLevel, _ message: String) {
    Task { @MainActor in LogStore.shared.add(level, message) }
}
