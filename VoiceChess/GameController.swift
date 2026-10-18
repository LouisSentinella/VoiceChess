import SwiftUI
import UIKit
import VoiceChessCore

/// Drives a voice game: listens, resolves transcripts through the server, speaks the replies.
@MainActor
final class GameController: ObservableObject {
    enum Status: String {
        case idle = "Idle"
        case listening = "Listening"
        case thinking = "Thinking"
        case speaking = "Speaking"
    }

    private enum Heard {
        case text(String)
        case nothing
        case failed
    }

    private static let confirmPhrases = ["yes", "no", "yeah", "yep", "nope", "play it", "cancel", "correct", "wrong"]

    let settings = AppSettings()
    let log = DebugLog()

    @Published private(set) var status: Status = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var playerLine = ""
    @Published private(set) var botLine = ""
    @Published private(set) var spokenLine = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var game: GameState?

    private let audio: AudioSessionController
    private let speaker: Speaker
    private let listener: SpeechListener
    private var flow: Task<Void, Never>?
    private var hintsTask: Task<Void, Never>?
    private var hints: [String] = []
    private var lastSpoken = ""
    private var prepared = false

    init() {
        audio = AudioSessionController(log: log)
        speaker = Speaker(log: log)
        listener = SpeechListener(log: log)
        listener.onPartial = { [weak self] text in self?.transcript = text }
        audio.onInterruptionBegan = { [weak self] in self?.interruptionBegan() }
        audio.onInterruptionEnded = { [weak self] shouldResume in self?.interruptionEnded(shouldResume: shouldResume) }
    }

    // MARK: Lifecycle

    /// One-time launch work: log environment, observe screen lock, ask for permissions.
    func prepare() async {
        guard !prepared else { return }
        prepared = true
        log.log("App started \(AppInfo.version), server \(settings.serverURL)")
        log.log("On-device recognition supported: \(listener.supportsOnDeviceRecognition)")
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log.log("Device locking (protected data unavailable)") }
        }
        center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log.log("Device unlocked (protected data available)") }
        }
        if let problem = await listener.requestPermissions() {
            errorMessage = problem
            log.log("Permissions: \(problem)")
        } else {
            log.log("Permissions: microphone and speech recognition granted")
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        let name: String
        switch phase {
        case .active: name = "active"
        case .inactive: name = "inactive"
        case .background: name = "background"
        @unknown default: name = "unknown"
        }
        log.log("scenePhase -> \(name) (status \(status.rawValue), engine running \(listener.isEngineRunning), listening \(listener.isListening), speaking \(speaker.isSpeaking))")
    }

    private func interruptionBegan() {
        cancelFlow()
        status = .idle
    }

    private func interruptionEnded(shouldResume: Bool) {
        guard shouldResume, settings.handsFree, game?.gameOver == false, status == .idle else { return }
        log.log("Hands-free: resuming listening after interruption")
        startFlow { [self] in try await conversation() }
    }

    // MARK: Actions

    /// The big button: ends the current utterance when listening, otherwise starts one.
    func pushToTalk() {
        switch status {
        case .thinking: return
        case .listening: listener.stopListening()
        case .idle, .speaking: startFlow { [self] in try await conversation() }
        }
    }

    func newGame() {
        startFlow { [self] in
            guard try await guarded({ try await beginNewGame() }) else { return }
            if settings.handsFree, game?.gameOver == false { try await conversation() }
        }
    }

    private func startFlow(_ body: @escaping @MainActor () async throws -> Void) {
        cancelFlow()
        flow = Task { [weak self] in
            do {
                try await body()
            } catch is CancellationError {
                return
            } catch {
                self?.log.log("Flow error: \(error.localizedDescription)")
                self?.errorMessage = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self?.status = .idle
        }
    }

    private func cancelFlow() {
        flow?.cancel()
        flow = nil
        speaker.stop()
        listener.cancel()
    }

    // MARK: Conversation

    private func conversation() async throws {
        errorMessage = nil
        while true {
            guard try await turn(), settings.handsFree, game?.gameOver == false else { return }
        }
    }

    /// One listen-and-respond cycle. Returns false when listening failed (do not loop).
    private func turn() async throws -> Bool {
        switch try await hear() {
        case .failed:
            return false
        case .nothing:
            if !settings.handsFree { try await speak("I did not hear anything.") }
            return true
        case let .text(text):
            _ = try await guarded { try await handle(text) }
            return true
        }
    }

    private func hear(contextual: [String]? = nil) async throws -> Heard {
        await hintsTask?.value
        try Task.checkCancellation()
        guard !speaker.isSpeaking else {
            log.log("Refusing to listen while speaking")
            return .failed
        }
        errorMessage = nil
        if let problem = await listener.requestPermissions() {
            errorMessage = problem
            log.log("Cannot listen: \(problem)")
            return .failed
        }
        try Task.checkCancellation()
        do {
            try audio.activate()
        } catch {
            errorMessage = "Audio session failed: \(error.localizedDescription)"
            log.log("Audio session activation failed: \(error.localizedDescription)")
            return .failed
        }
        listener.contextualStrings = contextual ?? hints
        transcript = ""
        status = .listening
        var outcome = await listener.listen()
        if outcome == .interrupted {
            log.log("Listening was interrupted by an audio change, retrying once")
            outcome = await listener.listen()
        }
        try Task.checkCancellation()
        switch outcome {
        case let .transcript(text):
            return .text(text)
        case .noSpeech:
            return .nothing
        case let .failed(message):
            errorMessage = message
            return .failed
        case .interrupted:
            errorMessage = "Audio route changed; tap to try again."
            return .failed
        case .cancelled:
            throw CancellationError()
        }
    }

    private func handle(_ text: String) async throws {
        log.log("Heard: '\(text)'")
        if let command = VoiceCommand.parse(text) {
            try await run(command)
            return
        }
        guard let game else {
            try await speak("No game in progress. Say new game.")
            return
        }
        guard !game.gameOver else {
            try await speak("The game is over. Say new game.")
            return
        }
        status = .thinking
        let response = try await makeAPI().say(gameID: game.id, transcript: text, confirm: settings.confirmBeforePlay)
        try Task.checkCancellation()
        switch response {
        case let .played(result):
            try await finishMove(result)
        case let .confirm(candidate, message):
            try await confirm(candidate: candidate, message: message, gameID: game.id)
        case let .ambiguous(message, candidates):
            try await speak(message)
            switch try await hear(contextual: hints + candidates.map(\.spoken)) {
            case let .text(answer): try await handle(answer)
            case .nothing: try await speak("I did not hear an answer.")
            case .failed: break
            }
        case let .noMatch(message):
            try await speak(message)
        }
    }

    private func confirm(candidate: MoveCandidate, message: String, gameID: String) async throws {
        try await speak(message)
        for attempt in 1...2 {
            switch try await hear(contextual: Self.confirmPhrases) {
            case let .text(answer):
                switch YesNo.parse(answer) {
                case .yes?:
                    status = .thinking
                    let result = try await makeAPI().move(gameID: gameID, move: candidate.san)
                    try Task.checkCancellation()
                    try await finishMove(result)
                    return
                case .no?:
                    try await speak("Cancelled")
                    return
                case nil:
                    log.log("Confirm: could not parse '\(answer)' as yes or no")
                }
            case .nothing:
                log.log("Confirm: no answer heard")
            case .failed:
                return
            }
            if attempt == 1 { try await speak("Please say yes or no.") }
        }
        try await speak("Cancelled")
    }

    private func run(_ command: VoiceCommand) async throws {
        log.log("Voice command: \(command)")
        switch command {
        case .newGame:
            try await beginNewGame()
        case .repeatLast:
            try await speak(lastSpoken.isEmpty ? "Nothing to repeat." : lastSpoken)
        case .readBoard, .readMyPieces:
            guard let game else {
                try await speak("No game in progress.")
                return
            }
            status = .thinking
            let board = try await makeAPI().boardRead(gameID: game.id)
            try Task.checkCancellation()
            let mine = board.spoken[board.player] ?? ""
            let theirs = board.spoken[board.player == "white" ? "black" : "white"] ?? ""
            if command == .readMyPieces {
                try await speak(mine, remember: true)
            } else {
                let white = board.player == "white" ? mine : theirs
                let black = board.player == "white" ? theirs : mine
                try await speak("White: \(white). Black: \(black).", remember: true)
            }
        }
    }

    // MARK: Game

    private func beginNewGame() async throws {
        status = .thinking
        let api = try makeAPI()
        let created = try await api.newGame(side: settings.side, opponent: "maia", level: settings.maiaLevel)
        try Task.checkCancellation()
        let previous = game?.id
        game = created.state
        transcript = ""
        playerLine = ""
        botLine = created.botMove?.spoken ?? ""
        refreshHints()
        if let previous {
            Task { [log] in
                do { try await api.deleteGame(gameID: previous) } catch { log.log("Deleting old game failed: \(error.localizedDescription)") }
            }
        }
        var text = "You are \(created.state.player)."
        if let bot = created.botMove { text += " I play \(bot.spoken)." }
        try await speak(text, remember: true)
    }

    private func finishMove(_ result: MoveResult) async throws {
        game = result.state
        playerLine = result.playerMove.spoken
        botLine = result.botMove?.spoken ?? ""
        refreshHints()
        var parts: [String] = []
        if let bot = result.botMove { parts.append(bot.spoken) }
        if let over = result.state.spokenResult { parts.append(over) }
        if !parts.isEmpty { try await speak(parts.joined(separator: ". "), remember: true) }
    }

    /// Fetches the legal-move phrases for the current position; `hear` waits for it.
    private func refreshHints() {
        hints = []
        guard let game, !game.gameOver else { return }
        let id = game.id
        hintsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.makeAPI().hints(gameID: id)
                self.hints = result.phrases
                self.log.log("Hints: \(result.phrases.count) phrases")
            } catch {
                self.log.log("Hints failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Speech and errors

    private func speak(_ text: String, remember: Bool = false) async throws {
        try Task.checkCancellation()
        do {
            try audio.activate()
        } catch {
            log.log("Audio session activation failed before speaking: \(error.localizedDescription)")
        }
        if remember { lastSpoken = text }
        spokenLine = text
        status = .speaking
        log.log("Speak: \(text)")
        await speaker.say(text)
        try Task.checkCancellation()
    }

    /// Runs `body`; API failures are shown, spoken briefly and swallowed. Returns whether it succeeded.
    private func guarded(_ body: () async throws -> Void) async throws -> Bool {
        do {
            try await body()
            return true
        } catch let error as APIError {
            errorMessage = error.localizedDescription
            log.log("API error: \(error.localizedDescription)")
            switch error {
            case .unreachable: try await speak("Cannot reach the server")
            case let .server(status, detail): try await speak(status >= 500 ? "Server error" : detail)
            case .invalidResponse: try await speak("Unexpected server response")
            }
            return false
        }
    }

    private func makeAPI() throws -> APIClient {
        guard let url = settings.baseURL else { throw APIError.unreachable("invalid server URL") }
        let log = self.log
        return APIClient(baseURL: url, log: { line in Task { @MainActor in log.log(line) } })
    }
}
