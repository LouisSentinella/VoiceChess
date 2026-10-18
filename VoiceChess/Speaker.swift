import AVFoundation

/// Text-to-speech. `say` suspends until the utterance has finished (or was stopped).
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let log: DebugLog
    private var current: AVSpeechUtterance?
    private var continuation: CheckedContinuation<Void, Never>?

    var isSpeaking: Bool { continuation != nil }

    init(log: DebugLog) {
        self.log = log
        // Prefer the best installed en-US / en-GB voice, skipping the novelty voices.
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            ($0.language == "en-US" || $0.language == "en-GB") && !$0.identifier.contains("speech.synthesis.voice")
        }
        voice = candidates.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "en-US")
        super.init()
        synthesizer.delegate = self
        log.log("TTS voice: \(voice?.name ?? "default") (\(voice?.language ?? "?"), quality \(voice?.quality.rawValue ?? 0))")
    }

    func say(_ text: String) async {
        if isSpeaking { stop() }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9

        // If the synthesizer never reports completion (e.g. after an audio interruption), do not hang forever.
        let limit = max(10, Double(text.count) * 0.2)
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled, let self, self.current === utterance else { return }
            self.log.log("TTS watchdog: no completion after \(Int(limit)) s, stopping")
            self.stop()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.current = utterance
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
        watchdog.cancel()
    }

    /// Stops any speech immediately and resumes the pending `say`.
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        complete(nil)
    }

    private func complete(_ utterance: AVSpeechUtterance?) {
        if let utterance, utterance !== current { return }
        current = nil
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.complete(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.complete(utterance) }
    }
}
