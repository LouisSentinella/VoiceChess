import Foundation

/// In-memory ring buffer of timestamped diagnostic lines, shown in the Debug log screen.
@MainActor
final class DebugLog: ObservableObject {
    struct Entry: Identifiable {
        let id: Int
        let line: String
    }

    static let capacity = 500

    @Published private(set) var entries: [Entry] = []
    private var nextID = 0

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ text: String) {
        let line = "\(Self.formatter.string(from: Date())) \(text)"
        entries.append(Entry(id: nextID, line: line))
        nextID += 1
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    func clear() {
        entries.removeAll()
    }

    var exportText: String {
        entries.map(\.line).joined(separator: "\n")
    }
}
