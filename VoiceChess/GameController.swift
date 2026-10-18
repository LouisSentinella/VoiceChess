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

    /// What to say after a move or at the start of a game, and whether to play the turn tone after it.
    private struct Announcement {
        var text: String?
        var tone: Bool
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
    /// The last text the app spoke for "repeat"; shown instead of the move list while the board is hidden.
    @Published private(set) var lastSpoken = ""
    /// Seconds left of a temporary reveal of the hidden board; 0 when it is not revealed.
    @Published private(set) var revealSecondsLeft = 0
    /// A post-game review is running (summary, moves, explanations or the "Next?" prompt).
    @Published private(set) var reviewing = false
    /// The reviewed move whose position is on the board.
    @Published private(set) var reviewMoment: ReviewMoment?

    private let audio: AudioSessionController
    private let speaker: Speaker
    private let listener: SpeechListener
    private var flow: Task<Void, Never>?
    /// Incremented whenever a flow starts or is cancelled; a flow that finds it changed is stale.
    private var flowID = 0
    private var hintsTask: Task<Void, Never>?
    private var hints: [String] = []
    private var prepared = false
    /// Consecutive listens that heard nothing; the "did not hear" line is spoken only for the first.
    private var silentCycles = 0
    /// What the user has not heard yet (the flow was stopped after the move was applied).
    private var pendingAnnouncement: Announcement?
    private var revealTask: Task<Void, Never>?
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
        log.log("App started \(AppInfo.version), server \(settings.serverURL), auto-listen \(settings.autoListen), server voice \(settings.serverVoiceEnabled), ask the coach \(settings.askCoach), help level \(settings.helpLevel.rawValue), board \(settings.boardHidden ? "hidden" : "shown")")
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
        if answering || reviewing {
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

    /// Cancels the coach's answer or the review (button tap) and listens again, or goes idle when auto-listen is off or paused.
    private func stopAnswer() {
        log.log("Stop tapped: cancelling the \(reviewing ? "review" : "coach's answer")")
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

    /// Reads `text` aloud (the mistake log). Auto-listen picks up again afterwards.
    func readAloud(_ text: String) {
        let resume = autoListening && shouldRelisten
        log.log("Read aloud: \(text)")
        startFlow { [self] in
            try await speak(text)
            if resume { try await conversation() }
        }
    }

    /// The Review button: goes through the worst moves of the game with explanations.
    func startReview() {
        paused = false
        resumeWanted = false
        log.log("Review requested by button")
        startFlow { [self] in
            guard try await guarded({ try await review() }) else { return }
            if shouldRelisten { try await conversation() }
        }
    }

    /// The Review button is offered once the game is over or has a few moves to go through.
    var canReview: Bool {
        guard let game, !reviewing else { return false }
        return game.gameOver || game.moves.count >= 4
    }

    // MARK: Board visibility

    static let revealSeconds = 10

    /// False while the board is hidden. The SAN move list and the last-move lines must then stay
    /// off the screen too, because they would give the position away.
    var movesVisible: Bool {
        !settings.boardHidden || revealSecondsLeft > 0
    }

    /// False while the board is hidden: the placeholder is shown instead. A review always shows its position.
    var boardVisible: Bool {
        movesVisible || reviewMoment != nil || game == nil
    }

    /// Shows a hidden board for `revealSeconds`, counting down once a second.
    func reveal() {
        revealTask?.cancel()
        revealSecondsLeft = Self.revealSeconds
        log.log("Board revealed for \(Self.revealSeconds) s")
        revealTask = Task { [weak self] in
            for _ in 0..<Self.revealSeconds {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.revealSecondsLeft -= 1
            }
        }
    }

    /// Hides a revealed board immediately.
    func endReveal() {
        revealTask?.cancel()
        revealTask = nil
        revealSecondsLeft = 0
    }

    func toggleReveal() {
        if revealSecondsLeft > 0 { endReveal() } else { reveal() }
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
        reviewing = false
        reviewMoment = nil
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
        case let .helpLevel(level):
            settings.helpLevel = level
            log.log("Help level set to \(level.rawValue)")
            switch level {
            case .full: try await speak("Help level full. I will announce every move.")
            case .moves: try await speak("Help level moves only. I will announce my moves.")
            case .nothing: try await speak("Help level nothing. You will hear a tone when it is your turn.")
            }
        case .showBoard:
            if settings.boardHidden {
                reveal()
            } else {
                log.log("Show the board: it is already shown")
            }
        case .hideBoard:
            settings.boardHidden = true
            endReveal()
            log.log("Board hidden by voice")
        case .review:
            try await review()
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
        _ = try await speakStream(api.ask(gameID: gameID, question: question), label: "Ask")
    }

    /// Speaks the sentences of an answer stream as they arrive and shows them in the coach box.
    /// Returns what was spoken. A broken stream is spoken once if it had already delivered something.
    private func speakStream(_ events: AnswerStream, label: String) async throws -> [String] {
        // The reader takes sentences off the network as they arrive and starts fetching the speech
        // for each one after the first, while the loop below speaks them one after another.
        let (sentences, relay) = Self.makeRelay()
        let reader = Task { [weak self] in
            var count = 0
            do {
                for try await event in events {
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

        var spoken: [String] = []
        do {
            for try await event in sentences {
                switch event {
                case let .sentence(text):
                    spoken.append(text)
                    try await speak(text)
                case let .error(message):
                    log.log("\(label): coach reported an error: \(message)")
                    spoken.append(message)
                    try await speak(message)
                case .done:
                    log.log("\(label) done: \(spoken.count) lines spoken")
                }
            }
        } catch let error as APIError where !spoken.isEmpty {
            log.log("\(label) stream broke after \(spoken.count) lines: \(error.localizedDescription)")
            appendCoach(Self.lostConnection)
            try await speak(Self.lostConnection)
        }
        return spoken
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

    // MARK: Review

    /// Goes through the listener's worst moves one by one: the position is shown with the move
    /// highlighted, the move and the better one are spoken, then the explanation streams in.
    /// Voice input during the review goes only to `reviewPrompt`, so no spoken move can reach /say.
    private func review() async throws {
        guard let game else {
            try await speak("No game in progress.")
            return
        }
        status = .thinking
        let api = try makeAPI()
        let review = try await api.review(gameID: game.id)
        try Task.checkCancellation()
        let id = flowID
        reviewing = true
        log.log("Review started: \(review.moments.count) moments")
        defer {
            if flowID == id {
                reviewing = false
                reviewMoment = nil
                clearCoach()
                log.log("Review ended")
            }
        }
        try await speak(review.summary)
        for (index, moment) in review.moments.enumerated() {
            reviewMoment = moment
            coachQuestion = "Move \(moment.moveNumber): \(moment.san)"
            coachAnswer = ""
            try await speak("Move \(moment.moveNumber): you played \(moment.spoken), \(moment.label). Better was \(moment.bestSpoken).")
            status = .thinking
            let explanation = try await speakStream(api.explain(gameID: game.id, ply: moment.ply), label: "Review ply \(moment.ply)")
            guard index < review.moments.count - 1 else { break }
            var command = try await reviewPrompt(gameID: game.id)
            while command == .repeatExplanation {
                for line in explanation { try await speak(line) }
                command = try await reviewPrompt(gameID: game.id)
            }
            if command == .leave { return }
        }
        if !review.moments.isEmpty { try await speak("That was the last one.") }
    }

    /// Asks "Next?" and waits for a review command. Questions go to the coach, anything else is refused.
    private func reviewPrompt(gameID: String) async throws -> ReviewCommand {
        try await speak("Next?")
        var silent = 0
        while true {
            switch try await hear(contextual: ReviewCommand.phrases) {
            case .failed:
                return .leave
            case .nothing:
                silent += 1
                if silent == 1 { try await speak("Say next, repeat, or stop.") }
            case let .text(text):
                log.log("Review heard: '\(text)'")
                if let command = ReviewCommand.parse(text) { return command }
                if QuestionDetector.isQuestion(text) {
                    _ = try await guarded { try await ask(text, gameID: gameID) }
                    try await speak("Next?")
                } else {
                    try await speak("We are reviewing; say stop to leave.")
                }
            }
        }
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
        var tone = false
        switch settings.helpLevel {
        case .full:
            if let bot = created.botMove { text += " I play \(bot.spoken)." }
            text += " Your move."
        case .moves:
            if let bot = created.botMove { text += " I play \(bot.spoken)." }
        case .nothing:
            tone = created.botMove != nil
        }
        log.log("Announcement at help level \(settings.helpLevel.rawValue): \(text)\(tone ? " + tone" : "")")
        pendingAnnouncement = Announcement(text: text, tone: tone)
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
        pendingAnnouncement = announcement(for: result)
    }

    /// What to say (and whether to play the turn tone) after a move, by help level:
    /// full announces both moves, check and the turn; moves only the bot's reply; nothing only the result and a tone.
    private func announcement(for result: MoveResult) -> Announcement? {
        let state = result.state
        let myTurn = !state.gameOver && state.yourTurn
        var parts: [String] = []
        switch settings.helpLevel {
        case .full:
            parts.append(result.playerMove.spoken)
            if let bot = result.botMove { parts.append(bot.spoken) }
            if state.inCheck, !state.gameOver { parts.append("You are in check") }
            if myTurn { parts.append("Your move") }
        case .moves:
            if let bot = result.botMove { parts.append(bot.spoken) }
        case .nothing:
            break
        }
        if let over = state.spokenResult { parts.append(over) }
        let tone = settings.helpLevel == .nothing && myTurn
        let text = parts.isEmpty ? nil : parts.joined(separator: ". ")
        log.log("Announcement at help level \(settings.helpLevel.rawValue): \(text ?? "-")\(tone ? " + tone" : "")")
        return text == nil && !tone ? nil : Announcement(text: text, tone: tone)
    }

    private func speakPending() async throws {
        guard let pending = pendingAnnouncement else { return }
        if let text = pending.text {
            try await speak(text, remember: true)
            pendingAnnouncement?.text = nil
        }
        if pending.tone { try await playTurnTone() }
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

    private func beginPlayback() throws {
        try Task.checkCancellation()
        do {
            try audio.activate()
        } catch {
            log.log("Audio session activation failed before playback: \(error.localizedDescription)")
        }
        status = .speaking
    }

    private func speak(_ text: String, remember: Bool = false) async throws {
        try beginPlayback()
        if remember { lastSpoken = text }
        log.log("Speak: \(text)")
        await speaker.say(text)
        try Task.checkCancellation()
    }

    /// The tone that tells the player it is their turn at help level Nothing.
    private func playTurnTone() async throws {
        try beginPlayback()
        log.log("Turn tone")
        await speaker.playTone()
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
