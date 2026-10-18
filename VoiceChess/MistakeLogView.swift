import SwiftUI
import VoiceChessCore

/// Shows the server's mistake log summary (`GET /log/summary`).
struct MistakeLogView: View {
    @ObservedObject var settings: AppSettings
    let controller: GameController
    @State private var summary: LogSummary?
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        List {
            if let problem {
                Section { Text(problem).foregroundStyle(.red) }
            }
            if let summary {
                Section("Summary") {
                    Text(summary.spoken)
                    LabeledContent("Illegal move attempts", value: "\(summary.illegalAttempts)")
                    LabeledContent("Board lookups", value: "\(summary.lookups)")
                }
                if !summary.byPiece.isEmpty {
                    Section("By piece") { countRows(summary.byPiece) }
                }
                if !summary.bySquare.isEmpty {
                    Section("By square") { countRows(summary.bySquare) }
                }
                Section("Recent") {
                    if summary.recent.isEmpty {
                        Text("Nothing logged yet").foregroundStyle(.secondary)
                    }
                    ForEach(Array(summary.recent.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Self.kindLabel(entry.kind)): \(entry.detail)")
                            Text(Self.timeLabel(entry.time)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if loading {
                Section { ProgressView() }
            }
            Section {
                Button("Refresh") { Task { await load() } }
                    .disabled(loading)
                Button("Read aloud") {
                    if let summary { controller.readAloud(summary.spoken) }
                }
                .disabled(summary == nil)
            }
        }
        .navigationTitle("Mistake log")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// Counts, largest first (ties alphabetical).
    private func countRows(_ counts: [String: Int]) -> some View {
        let keys = counts.keys.sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 }
        return ForEach(keys, id: \.self) { key in
            LabeledContent(key.capitalized, value: "\(counts[key] ?? 0)")
        }
    }

    private func load() async {
        loading = true
        problem = nil
        defer { loading = false }
        do {
            summary = try await settings.makeAPI(log: controller.log).logSummary()
        } catch {
            problem = "Could not load the mistake log: \(error.localizedDescription)"
        }
    }

    private static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "illegal_attempt": return "Illegal move"
        case "lookup": return "Lookup"
        default: return kind
        }
    }

    private static func timeLabel(_ time: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: time) else { return time }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
