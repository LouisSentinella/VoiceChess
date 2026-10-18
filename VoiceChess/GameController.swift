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
    @Published private(set) var errorMessage: String?
    @Published private(set) var game: GameState?
    /// Auto-listen is paused by the user or by a hard error; cleared by Listen or a new game.
    @Published private(set) var paused = false
    /// A listening/speaking flow is in progress.
    @Published private(set) var flowActive = false
    /// The last question put to the coach and its answer as it streams in. Kept until the next move or question.
    @Published private(set) var coachQuestion = ""
    @Published private(set) var coachAnswer = ""
    /// The coach is thinking about or speaking an answer; the big button then stops it.
    @Published private(set) var answering = false

    private let audio: AudioSessionController
    private let speaker: Speaker
    private let listener: SpeechListener
    private var flow: Task<Void, Never>?
    /// Incremented whenever a flow starts or is cancelled; a flow that finds it changed is stale.
    private var flowID = 0
    private var hintsTask: Task<Void, Never>?
    private var hints: [String] = []
    private var lastSpoken = ""
    private var prepared = false
    /// Consecutive listens that heard nothing; the "did not hear" line is spoken only for the first.
    private var silentCycles = 0
    /// Reply the user has not heard yet (the flow was stopped after the move was applied).
    private var pendingAnnouncement: String?
    private var appActive = true
    private var interrupted = false
    /// Auto-listen was running when the system stopped it; resume when the app is active and uninterrupted.
    private var resumeWanted = false

    init() {
        audio = AudioSessionController(log: log)
        speaker = Speaker(settings: settings, log: log)
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
        log.log("App started \(AppInfo.version), server \(settings.serverURL), auto-listen \(settings.autoListen), server voice \(settings.serverVoiceEnabled), ask the coach \(settings.askCoach)")
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
        appActive = phase == .active
        switch phase {
        case .background: stopForSystem("app moved to background")
        case .active: resumeIfWanted("app became active")
        default: break
        }
    }

    private func interruptionBegan() {
        interrupted = true
        stopForSystem("audio interruption began")
    }

    private func interruptionEnded(shouldResume: Bool) {
        interrupted = false
        log.log("Audio interruption over (system shouldResume: \(shouldResume))")
        resumeIfWanted("audio interruption ended")
    }

    /// Stops all speech and listening because the system took the audio or the screen away.
    /// Auto-listen resumes by itself later only if it was running.
    private func stopForSystem(_ reason: String) {
        if flowActive, settings.autoListen, !paused { resumeWanted = true }
        log.log("Stopping: \(reason) (status \(status.rawValue), resume later: \(resumeWanted))")
        cancelFlow()
        status = .idle
    }

    private func resumeIfWanted(_ reason: String) {
        guard resumeWanted else { return }
        guard appActive, !interrupted else {
            log.log("Resume deferred after \(reason): app active \(appActive), interrupted \(interrupted)")
            return
        }
        resumeWanted = false
        guard settings.autoListen, !paused else {
            log.log("Not resuming after \(reason): auto-listen \(settings.autoListen), paused \(paused)")
            return
        }
        log.log("Auto-listen resuming after \(reason)")
        startFlow { [self] in try await conversation() }
    }

    // MARK: Actions

    /// True while auto-listen is on and actively running (the button then reads Pause).
    var autoListening: Bool { settings.autoListen && !paused && flowActive }

    /// True when auto-listen is on but stopped by the user or by an error.
    var autoListenPaused: Bool { settings.autoListen && paused }

    /// The big button: Pause while auto-listen runs; otherwise Listen (push-to-talk), or Done while listening.
    func primaryAction() {
        if answering {
            stopAnswer()
            return
        }
        if autoListening {
            pause("user tapped Pause")
            return
        }
        switch status {
        case .thinking:
            return
        case .listening:
            log.log("Done tapped: ending utterance")
            listener.stopListening()
        case .idle, .speaking:
            paused = false
            resumeWanted = false
            log.log("Listen tapped (auto-listen \(settings.autoListen ? "on" : "off"), status \(status.rawValue))")
            startFlow { [self] in try await conversation() }
        }
    }

    /// Cancels the coach's answer (button tap) and listens again, or goes idle when auto-listen is off or paused.
    private func stopAnswer() {
        log.log("Stop tapped: cancelling the coach's answer")
        cancelFlow()
        status = .idle
        if shouldRelisten { startFlow { [self] in try await conversation() } }
    }

    private func pause(_ reason: String) {
        paused = true
        resumeWanted = false
        log.log("Auto-listen paused: \(reason)")
        cancelFlow()
        status = .idle
    }

    func newGame() {
        paused = false
        resumeWanted = false
        log.log("New game requested")
        startFlow { [self] in
            guard try await guarded({ try await beginNewGame() }) else { return }
            if shouldRelisten { try await conversation() }
        }
    }

    /// Speaks a sample move so the voice settings can be judged. Auto-listen picks up again afterwards.
    func testVoice() {
        let resume = autoListening && shouldRelisten
        log.log("Test voice")
        startFlow { [self] in
            try await speak("Knight to f3, check")
            if resume { try await conversation() }
        }
    }

    /// Whether to listen again after the current turn.
    private var shouldRelisten: Bool { settings.autoListen && !paused }

    private func startFlow(_ body: @escaping @MainActor () async throws -> Void) {
        cancelFlow()
        flowID += 1
        let id = flowID
        flowActive = true
        flow = Task { [weak self] in
            var failure: Error?
            do {
                try Task.checkCancellation()
                try await body()
            } catch is CancellationError {
                return
            } catch {
                failure = error
            }
            guard let self, self.flowID == id else { return }
            if let failure {
                self.log.log("Flow error: \(failure.localizedDescription)")
                self.errorMessage = failure.localizedDescription
                self.paused = true
            }
            self.status = .idle
            self.flowActive = false
            self.flow = nil
        }
    }

    private func cancelFlow() {
        flowID += 1
        flow?.cancel()
        flow = nil
        flowActive = false
        answering = false
        speaker.stop()
        listener.cancel()
    }

    // MARK: Conversation

    /// Listens and responds once; with auto-listen on, keeps going until the game ends,
    /// the user pauses, or a hard error occurs.
    private func conversation() async throws {
        errorMessage = nil
        try await speakPending()
        while true {
            guard try await turn(), shouldRelisten else {
                log.log("Conversation ends (auto-listen \(settings.autoListen), paused \(paused), game over \(game?.gameOver == true))")
                return
            }
        }
    }

    /// One listen-and-respond cycle. Returns false when listening failed (do not loop).
    private func turn() async throws -> Bool {
        switch try await hear() {
        case .failed:
            return false
        case .nothing:
            silentCycles += 1
            // Push-to-talk always answers; auto-listen says it once, then keeps listening silently.
            if !settings.autoListen || silentCycles == 1 { try await speak("I did not hear anything.") }
            return true
        case let .text(text):
            silentCycles = 0
            _ = try await guarded { try await handle(text) }
            return true
        }
    }

    /// A listen that cannot proceed: shows the problem and pauses auto-listen until the user taps Listen.
    private func hardFailure(_ message: String) -> Heard {
        errorMessage = message
        if settings.autoListen, !paused {
            paused = true
            log.log("Auto-listen paused: \(message)")
        }
        return .failed
    }

    private func hear(contextual: [String]? = nil) async throws -> Heard {
        await hintsTask?.value
        try Task.checkCancellation()
        guard !speaker.isSpeaking else {
            log.log("Refusing to listen while speaking")
            return hardFailure("Tried to listen while speaking.")
        }
        errorMessage = nil
        if let problem = await listener.requestPermissions() {
            log.log("Cannot listen: \(problem)")
            return hardFailure(problem)
        }
        try Task.checkCancellation()
        do {
            try audio.activate()
        } catch {
            log.log("Audio session activation failed: \(error.localizedDescription)")
            return hardFailure("Audio session failed: \(error.localizedDescription)")
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
            return hardFailure(message)
        case .interrupted:
            return hardFailure("Audio route changed; tap Listen to try again.")
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
        status = .thinking
        let response = try await makeAPI().say(gameID: game.id, transcript: text, confirm: settings.confirmBeforePlay)
        // The server has already played the move: keep the board in sync even if the flow was stopped.
        if case let .played(result) = response { applyMove(result) }
        try Task.checkCancellation()
        switch response {
        case .played:
            try await speakPending()
        case let .confirm(candidate, message):
            try await confirm(candidate: candidate, message: message, gameID: game.id)
        case let .ambiguous(message, candidates):
            try await speak(message)
            switch try await hear(contextual: hints + candidates.map(\.spoken)) {
            case let .text(answer): try await handle(answer)
            case .nothing:
                silentCycles += 1
                try await speak("I did not hear an answer.")
            case .failed: break
            }
        case let .noMatch(message):
            try await speak(message)
        case let .question(question):
            try await ask(question, gameID: game.id)
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
                    applyMove(result)
                    try Task.checkCancellation()
                    try await speakPending()
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
        case .stop:
            // Only heard while listening, when no answer is playing; it must never reach /say.
            log.log("Stop heard while listening: nothing to stop")
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

    // MARK: Coach

    private typealias AnswerStream = AsyncThrowingStream<AskEvent, Error>
    private static let coachOff = "Coach is off"
    private static let lostConnection = "Sorry, I lost the connection"

    /// Sends `question` to the coach and speaks the answer sentence by sentence as it streams in.
    /// The board is not touched. A broken stream is spoken once; other failures propagate to `guarded`.
    private func ask(_ question: String, gameID: String) async throws {
        coachQuestion = question
        coachAnswer = ""
        guard settings.askCoach else {
            log.log("Question ignored: ask the coach is off")
            coachAnswer = Self.coachOff
            try await speak(Self.coachOff)
            return
        }
        let api = try makeAPI()
        let id = flowID
        answering = true
        defer { if flowID == id { answering = false } }
        status = .thinking
        log.log("Ask: '\(question)'")

        // The reader takes sentences off the network as they arrive and starts fetching the speech
        // for each one after the first, while the loop below speaks them one after another.
        let (sentences, relay) = Self.makeRelay()
        let reader = Task { [weak self] in
            var count = 0
            do {
                for try await event in api.ask(gameID: gameID, question: question) {
                    switch event {
                    case let .sentence(text):
                        count += 1
                        if count > 1 { self?.speaker.prefetch(text) }
                        self?.appendCoach(text)
                    case let .error(message):
                        self?.appendCoach(message)
                    case .done:
                        break
                    }
                    relay.yield(event)
                }
                relay.finish()
            } catch {
                relay.finish(throwing: error)
            }
        }
        defer { reader.cancel() }

        var spoken = 0
        do {
            for try await event in sentences {
                switch event {
                case let .sentence(text):
                    spoken += 1
                    try await speak(text)
                case let .error(message):
                    log.log("Ask: coach reported an error: \(message)")
                    try await speak(message)
                case .done:
                    log.log("Ask done: \(spoken) sentences spoken")
                }
            }
        } catch let error as APIError where spoken > 0 {
            log.log("Ask stream broke after \(spoken) sentences: \(error.localizedDescription)")
            appendCoach(Self.lostConnection)
            try await speak(Self.lostConnection)
        }
    }

    private func appendCoach(_ text: String) {
        coachAnswer += coachAnswer.isEmpty ? text : " " + text
    }

    private func clearCoach() {
        coachQuestion = ""
        coachAnswer = ""
    }

    private static func makeRelay() -> (AnswerStream, AnswerStream.Continuation) {
        var continuation: AnswerStream.Continuation!
        let stream = AnswerStream { continuation = $0 }
        return (stream, continuation)
    }

    // MARK: Game

    private func beginNewGame() async throws {
        status = .thinking
        let api = try makeAPI()
        let created = try await api.newGame(side: settings.side, opponent: "maia", level: settings.maiaLevel)
        let previous = game?.id
        game = created.state
        transcript = ""
        playerLine = ""
        botLine = created.botMove?.spoken ?? ""
        clearCoach()
        silentCycles = 0
        refreshHints()
        var text = "You are \(created.state.player)."
        if let bot = created.botMove { text += " I play \(bot.spoken)." }
        pendingAnnouncement = text
        if let previous {
            Task { [log] in
                do { try await api.deleteGame(gameID: previous) } catch { log.log("Deleting old game failed: \(error.localizedDescription)") }
            }
        }
        try Task.checkCancellation()
        try await speakPending()
    }

    /// Updates the board and the reply to speak. Runs before any cancellation check so the screen
    /// always matches the server, and a reply cut off by a pause is spoken when listening resumes.
    private func applyMove(_ result: MoveResult) {
        game = result.state
        playerLine = result.playerMove.spoken
        botLine = result.botMove?.spoken ?? ""
        clearCoach()
        refreshHints()
        var parts: [String] = []
        if let bot = result.botMove { parts.append(bot.spoken) }
        if let over = result.state.spokenResult { parts.append(over) }
        pendingAnnouncement = parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    private func speakPending() async throws {
        guard let text = pendingAnnouncement else { return }
        try await speak(text, remember: true)
        pendingAnnouncement = nil
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
            case let .server(status, detail):
                if status == 409, game?.gameOver == true {
                    try await speak("The game is over. Ask me about it.")
                } else {
                    try await speak(status >= 500 ? "Server error" : detail)
                }
            case .invalidResponse: try await speak("Unexpected server response")
            }
            return false
        }
    }

    private func makeAPI() throws -> APIClient {
        try settings.makeAPI(log: log)
    }
}
