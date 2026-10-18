import SwiftUI
import VoiceChessCore

struct ContentView: View {
    @ObservedObject var controller: GameController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showLog = false
    @State private var showNewGame = false

    var body: some View {
        VStack(spacing: 14) {
            header
            statusBlock
            Spacer(minLength: 0)
            talkButton
            Button {
                showNewGame = true
            } label: {
                Label("New Game", systemImage: "plus.circle.fill")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(.gray)
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView(settings: controller.settings) }
        .sheet(isPresented: $showLog) { DebugLogView(log: controller.log) }
        .sheet(isPresented: $showNewGame) { NewGameView(settings: controller.settings, controller: controller) }
        .task { await controller.prepare() }
        .onChange(of: scenePhase) { _, phase in controller.scenePhaseChanged(phase) }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice Chess").font(.title.bold())
                Text(gameSummary).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showLog = true } label: {
                Image(systemName: "doc.text.magnifyingglass").font(.title2).frame(width: 52, height: 52)
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title2).frame(width: 52, height: 52)
            }
        }
    }

    private var gameSummary: String {
        guard let game = controller.game else { return "No game. Tap New Game." }
        let opponent = game.opponent.level.map { "Maia \($0)" } ?? game.opponent.type.capitalized
        let turn = game.gameOver ? "game over" : (game.yourTurn ? "your move" : "bot to move")
        return "You are \(game.player) vs \(opponent), \(turn)"
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 16, height: 16)
                Text(controller.status.rawValue).font(.title2.bold())
            }
            Text(controller.transcript.isEmpty ? " " : "\u{201C}\(controller.transcript)\u{201D}")
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            lineRow("You", controller.playerLine)
            lineRow("Bot", controller.botLine)
            lineRow("Said", controller.spokenLine)
            if let error = controller.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lineRow(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.footnote.bold()).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            Text(text.isEmpty ? "-" : text).font(.body).lineLimit(3)
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .idle: return .gray
        case .listening: return .red
        case .thinking: return .orange
        case .speaking: return .green
        }
    }

    private var talkButton: some View {
        Button {
            controller.pushToTalk()
        } label: {
            VStack(spacing: 12) {
                Image(systemName: talkIcon).font(.system(size: 88))
                Text(talkLabel).font(.title.bold())
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(talkColor, in: RoundedRectangle(cornerRadius: 36))
        }
        .buttonStyle(.plain)
        .disabled(controller.status == .thinking)
        .frame(minHeight: 240)
    }

    private var talkIcon: String {
        switch controller.status {
        case .idle: return "mic.fill"
        case .listening: return "stop.circle.fill"
        case .thinking: return "hourglass"
        case .speaking: return "speaker.wave.3.fill"
        }
    }

    private var talkLabel: String {
        switch controller.status {
        case .idle: return "Tap to talk"
        case .listening: return "Tap when done"
        case .thinking: return "Thinking"
        case .speaking: return "Tap to interrupt"
        }
    }

    private var talkColor: Color {
        switch controller.status {
        case .idle: return .blue
        case .listening: return .red
        case .thinking: return .gray
        case .speaking: return .green
        }
    }
}
