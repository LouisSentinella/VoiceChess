import AVFoundation
import Speech

enum ListenOutcome: Equatable {
    case transcript(String)
    case noSpeech
    case failed(String)
    /// The audio engine configuration changed (route switch); the caller may retry.
    case interrupted
    case cancelled
}

private struct RecognitionFailure {
    let domain: String
    let code: Int
    let description: String
}

// The functions below are file-scope (nonisolated) on purpose: their closures run on audio and
// Speech framework queues and must not inherit @MainActor isolation.

private func installTap(on input: AVAudioInputNode, format: AVAudioFormat, request: SFSpeechAudioBufferRecognitionRequest) {
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        request.append(buffer)
    }
}

private func startRecognition(
    recognizer: SFSpeechRecognizer,
    request: SFSpeechAudioBufferRecognitionRequest,
    handler: @escaping @Sendable (String?, Bool, RecognitionFailure?) -> Void
) -> SFSpeechRecognitionTask {
    recognizer.recognitionTask(with: request) { result, error in
        let failure = (error as NSError?).map {
            RecognitionFailure(domain: $0.domain, code: $0.code, description: $0.localizedDescription)
        }
        handler(result?.bestTranscription.formattedString, result?.isFinal ?? false, failure)
    }
}

private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
}

private func requestMicrophonePermission() async -> Bool {
    await withCheckedContinuation { continuation in
        AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
    }
}

/// One-utterance-at-a-time speech recognition (SFSpeechRecognizer + AVAudioEngine).
/// An utterance ends after `silenceTimeout` without a new partial result, or on `stopListening()`.
@MainActor
final class SpeechListener {
    static let silenceTimeout: TimeInterval = 1.2
    static let noSpeechTimeout: TimeInterval = 8
    static let finalizeTimeout: TimeInterval = 1.5

    /// Live partial transcript.
    var onPartial: ((String) -> Void)?
    /// Phrases biasing recognition (legal moves in spoken form).
    var contextualStrings: [String] = []

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let log: DebugLog
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<ListenOutcome, Never>?
    private var timer: Task<Void, Never>?
    private var latest = ""
    private var audioEnded = false
    /// Incremented per utterance and on finish; callbacks from an older utterance are ignored.
    private var generation = 0

    var isListening: Bool { continuation != nil }
    var isEngineRunning: Bool { engine.isRunning }

    init(log: DebugLog) {
        self.log = log
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
    }

    /// Asks for microphone and speech permission. Returns a user-facing problem description, or nil if ready.
    func requestPermissions() async -> String? {
        if !(await requestMicrophonePermission()) {
            return "Microphone access is denied. Enable it in Settings > Voice Chess."
        }
        switch await requestSpeechAuthorization() {
        case .authorized: break
        case .denied: return "Speech recognition is denied. Enable it in Settings > Voice Chess."
        case .restricted: return "Speech recognition is restricted on this device."
        case .notDetermined: return "Speech recognition permission has not been granted."
        @unknown default: return "Speech recognition permission is unavailable."
        }
        guard let recognizer else { return "Speech recognition does not support English (US) on this device." }
        guard recognizer.isAvailable else { return "Speech recognizer is currently unavailable." }
        return nil
    }

    var supportsOnDeviceRecognition: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    func listen() async -> ListenOutcome {
        guard continuation == nil else { return .failed("Already listening") }
        guard let recognizer, recognizer.isAvailable else { return .failed("Speech recognizer unavailable") }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let onDevice = recognizer.supportsOnDeviceRecognition
        if onDevice { request.requiresOnDeviceRecognition = true }
        request.contextualStrings = contextualStrings

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log.log("Recognizer: no usable audio input (sampleRate \(format.sampleRate), channels \(format.channelCount))")
            return .failed("No audio input available")
        }
        installTap(on: input, format: format, request: request)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            log.log("Audio engine start failed: \(error.localizedDescription)")
            return .failed("Audio engine failed to start: \(error.localizedDescription)")
        }

        latest = ""
        audioEnded = false
        generation += 1
        let id = generation
        self.request = request
        task = startRecognition(recognizer: recognizer, request: request) { [weak self] text, isFinal, failure in
            Task { @MainActor in self?.handleResult(id: id, text: text, isFinal: isFinal, failure: failure) }
        }
        log.log("Recognizer start (onDevice: \(onDevice), hints: \(contextualStrings.count), input \(Int(format.sampleRate)) Hz)")
        armTimer(Self.noSpeechTimeout, id: id) { [weak self] in
            self?.log.log("Recognizer: no speech within \(Int(Self.noSpeechTimeout)) s")
            self?.finish(.noSpeech)
        }
        return await withCheckedContinuation { self.continuation = $0 }
    }

    /// Ends the current utterance now (button tap) and returns what was heard.
    func stopListening() {
        guard isListening else { return }
        log.log("Recognizer: utterance ended by button")
        endAudio()
    }

    func cancel() {
        finish(.cancelled)
    }

    private func handleResult(id: Int, text: String?, isFinal: Bool, failure: RecognitionFailure?) {
        guard id == generation, isListening else { return }
        if let text, !text.isEmpty, text != latest {
            latest = text
            onPartial?(text)
            if !audioEnded {
                armTimer(Self.silenceTimeout, id: id) { [weak self] in
                    self?.log.log("Recognizer: \(Self.silenceTimeout) s of silence, ending utterance")
                    self?.endAudio()
                }
            }
        }
        if let failure {
            log.log("Recognizer error \(failure.domain) \(failure.code): \(failure.description)")
            if !latest.isEmpty {
                finish(.transcript(latest))
            } else if failure.code == 1110 {
                finish(.noSpeech)
            } else {
                finish(.failed("Recognition error: \(failure.description)"))
            }
            return
        }
        if isFinal {
            log.log("Recognizer final result: '\(latest)'")
            finish(latest.isEmpty ? .noSpeech : .transcript(latest))
        }
    }

    /// Stops capturing and waits briefly for the recognizer's final result.
    private func endAudio() {
        guard isListening, !audioEnded else { return }
        audioEnded = true
        stopEngine()
        request?.endAudio()
        armTimer(Self.finalizeTimeout, id: generation) { [weak self] in
            guard let self else { return }
            self.log.log("Recognizer: no final result after \(Self.finalizeTimeout) s, using partial '\(self.latest)'")
            self.finish(self.latest.isEmpty ? .noSpeech : .transcript(self.latest))
        }
    }

    private func finish(_ outcome: ListenOutcome) {
        guard let pending = continuation else { return }
        continuation = nil
        generation += 1
        timer?.cancel()
        timer = nil
        stopEngine()
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        log.log("Recognizer stop: \(outcome)")
        pending.resume(returning: outcome)
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func handleConfigurationChange() {
        guard isListening else {
            log.log("Audio engine configuration changed while idle")
            return
        }
        log.log("Audio engine configuration changed while listening (engine running: \(engine.isRunning))")
        finish(latest.isEmpty ? .interrupted : .transcript(latest))
    }

    private func armTimer(_ seconds: TimeInterval, id: Int, action: @escaping @MainActor () -> Void) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == id else { return }
            action()
        }
    }
}
