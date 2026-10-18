import SwiftUI
import VoiceChessCore

struct ContentView: View {
    @ObservedObject var controller: GameController
    /// Observed directly so the button reacts to the auto-listen setting.
    @ObservedObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showLog = false
    @State private var showNewGame = false

    init(controller: GameController) {
        self.controller = controller
        _settings = ObservedObject(wrappedValue: controller.settings)
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            board
            movesLine
            if !controller.coachQuestion.isEmpty { coachBox }
            statusLine
            transcriptBox
            lastMoves
            talkButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView(settings: controller.settings, controller: controller) }
        .sheet(isPresented: $showLog) { DebugLogView(log: controller.log) }
        .sheet(isPresented: $showNewGame) { NewGameView(settings: controller.settings, controller: controller) }
        .task { await controller.prepare() }
        .onChange(of: scenePhase) { _, phase in controller.scenePhaseChanged(phase) }
    }

    // MARK: Header and board

    private var header: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Voice Chess").font(.headline.bold())
                Text(gameSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if controller.canReview {
                headerButton("list.bullet.clipboard") { controller.startReview() }
            }
            headerButton("plus.circle.fill") { showNewGame = true }
            headerButton("doc.text.magnifyingglass") { showLog = true }
            headerButton("gearshape.fill") { showSettings = true }
        }
    }

    private func headerButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).frame(width: 44, height: 44)
        }
    }

    private var gameSummary: String {
        guard let game = controller.game else { return "No game yet" }
        let opponent = game.opponent.level.map { "Maia \($0)" } ?? game.opponent.type.capitalized
        let turn = game.gameOver ? "game over" : (game.yourTurn ? "your move" : "bot to move")
        return "You are \(game.player) vs \(opponent), \(turn)"
    }

    /// The board, or a placeholder of the same size while hidden. During a review the reviewed
    /// position is shown with the move highlighted, even when the board is normally hidden.
    @ViewBuilder
    private var board: some View {
        if controller.boardVisible { visibleBoard } else { hiddenBoard }
    }

    private var displayedPosition: BoardPosition {
        if let moment = controller.reviewMoment,
           let reviewed = BoardPosition(fen: moment.fenBefore, lastMoveUci: moment.uci) {
            return reviewed
        }
        return controller.game.flatMap { BoardPosition(state: $0) } ?? BoardPosition.start
    }

    private var visibleBoard: some View {
        BoardView(position: displayedPosition, flipped: controller.game?.player == "black")
            .overlay {
                if controller.game == nil {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55))
                        Button {
                            showNewGame = true
                        } label: {
                            Label("Start a new game", systemImage: "plus.circle.fill")
                                .font(.title2.bold())
                                .padding(.horizontal, 20)
                                .frame(minHeight: 56)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if revealed { revealCountdown }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if revealed { controller.endReveal() }
            }
    }

    /// The board is showing only because Reveal was tapped.
    private var revealed: Bool {
        settings.boardHidden && controller.reviewMoment == nil && controller.revealSecondsLeft > 0
    }

    private var hiddenBoard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.1))
            VStack(spacing: 16) {
                Image(systemName: "eye.slash.fill").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Board hidden").font(.title2.bold())
                Button {
                    controller.toggleReveal()
                } label: {
                    Label("Reveal", systemImage: "eye.fill")
                        .font(.title2.bold())
                        .padding(.horizontal, 24)
                        .frame(minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Ring and number counting down the seconds the board stays revealed; tapping hides it at once.
    private var revealCountdown: some View {
        let left = controller.revealSecondsLeft
        return Button {
            controller.endReveal()
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.25), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: CGFloat(left) / CGFloat(GameController.revealSeconds))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: left)
                    Text("\(left)").font(.caption.bold().monospacedDigit())
                }
                .frame(width: 28, height: 28)
                Text("Hide").font(.subheadline.bold())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.75), in: Capsule())
        }
        .padding(8)
    }

    /// The recent SAN moves; blank (not removed, so the layout stays put) while the board is hidden.
    private var movesLine: some View {
        let text = controller.movesVisible ? (controller.game.map { MoveList.recent($0.moves) } ?? "") : ""
        return Text(text.isEmpty ? " " : text)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Coach

    private static let coachEnd = "coachEnd"

    /// The last question and the answer as it streams in. Fixed height and scrollable, so a long
    /// answer never pushes the board or the big button off a small screen.
    private var coachBox: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Coach").font(.caption.bold()).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\u{201C}\(controller.coachQuestion)\u{201D}")
                            .font(.footnote.italic())
                            .foregroundStyle(.secondary)
                        Text(controller.coachAnswer.isEmpty ? "..." : controller.coachAnswer)
                            .font(.callout)
                        Color.clear.frame(height: 1).id(Self.coachEnd)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .onChange(of: controller.coachAnswer) { _, _ in
                    withAnimation { proxy.scrollTo(Self.coachEnd, anchor: .bottom) }
                }
            }
            .frame(height: 64)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Status

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 14, height: 14)
                Text(statusText).font(.headline.bold())
                Spacer()
                Text(settings.autoListen ? "Auto-listen on" : "Auto-listen off")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = controller.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    private var transcriptBox: some View {
        Text(controller.transcript.isEmpty ? " " : "\u{201C}\(controller.transcript)\u{201D}")
            .font(.title3)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(10)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Both players' last moves; while the board is hidden only what was last spoken.
    private var lastMoves: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if controller.movesVisible {
                lineRow("You", controller.playerLine)
                lineRow("Bot", controller.botLine)
            } else {
                lineRow("Said", controller.lastSpoken)
            }
        }
    }

    private func lineRow(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.footnote.bold()).foregroundStyle(.secondary)
            Text(text.isEmpty ? "-" : text).font(.callout).lineLimit(2).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusText: String {
        if controller.autoListenPaused, controller.status == .idle { return "Paused" }
        return controller.status.rawValue
    }

    private var statusColor: Color {
        if controller.autoListenPaused, controller.status == .idle { return .yellow }
        switch controller.status {
        case .idle: return .gray
        case .listening: return .red
        case .thinking: return .orange
        case .speaking: return .green
        }
    }

    // MARK: Talk button

    private enum ButtonMode { case stop, pause, done, thinking, listen }

    private var buttonMode: ButtonMode {
        if controller.answering || controller.reviewing { return .stop }
        if controller.autoListening { return .pause }
        switch controller.status {
        case .listening: return .done
        case .thinking: return .thinking
        case .idle, .speaking: return .listen
        }
    }

    private var talkButton: some View {
        let mode = buttonMode
        return Button {
            controller.primaryAction()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon(mode)).font(.system(size: 52))
                Text(label(mode)).font(.system(size: 32, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color(mode), in: RoundedRectangle(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .disabled(mode == .thinking)
        .frame(minHeight: 110)
    }

    private func icon(_ mode: ButtonMode) -> String {
        switch mode {
        case .stop: return "speaker.slash.fill"
        case .pause: return "pause.circle.fill"
        case .done: return "stop.circle.fill"
        case .thinking: return "hourglass"
        case .listen: return "mic.fill"
        }
    }

    private func label(_ mode: ButtonMode) -> String {
        switch mode {
        case .stop: return "Stop"
        case .pause: return "Pause"
        case .done: return "Done"
        case .thinking: return "Thinking"
        case .listen: return "Listen"
        }
    }

    private func color(_ mode: ButtonMode) -> Color {
        switch mode {
        case .stop: return .indigo
        case .pause: return .orange
        case .done: return .red
        case .thinking: return .gray
        case .listen: return .blue
        }
    }
}
