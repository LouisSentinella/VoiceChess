import AVFoundation
import VoiceChessCore

/// Installed on-device voices usable as the offline fallback.
enum LocalVoices {
    private static let languages = ["en-US", "en-GB", "en-AU"]

    /// en-US / en-GB / en-AU voices, best quality first, skipping the novelty voices.
    static func installed() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { languages.contains($0.language) && !$0.identifier.contains("speech.synthesis.voice") }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                let la = languages.firstIndex(of: a.language) ?? languages.count
                let lb = languages.firstIndex(of: b.language) ?? languages.count
                if la != lb { return la < lb }
                return a.name < b.name
            }
    }

    static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }

    static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        "\(voice.name) (\(voice.language), \(qualityLabel(voice.quality)))"
    }

    /// The chosen voice, or the best installed one when `id` is empty or no longer installed.
    static func resolve(id: String) -> AVSpeechSynthesisVoice? {
        if !id.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: id) { return chosen }
        return installed().first ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

/// Text-to-speech. `say` suspends until the line has finished playing (or was stopped).
/// It tries the server's /tts voice first and falls back to AVSpeechSynthesizer on any failure.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private static let serverTimeout: TimeInterval = 2.5
    private static let cacheLimit = 200

    private let synthesizer = AVSpeechSynthesizer()
    private let settings: AppSettings
    private let log: DebugLog
    /// WAV data keyed by server voice and text.
    private var cache: [String: Data] = [:]
    /// Server audio requests that have not finished, by cache key.
    private var inflight: [String: Task<Data?, Never>] = [:]
    private var utterance: AVSpeechUtterance?
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?
    /// Incremented by every `say` and `stop`; a `say` that finds it changed was superseded.
    private var generation = 0
    private var busy = false

    /// True from the start of `say` (including the server request) until playback has ended.
    var isSpeaking: Bool { busy }

    init(settings: AppSettings, log: DebugLog) {
        self.settings = settings
        self.log = log
        super.init()
        synthesizer.delegate = self
        let local = LocalVoices.resolve(id: settings.localVoiceID)
        log.log("TTS: server voice \(settings.serverVoiceEnabled ? "on" : "off"), local fallback \(local.map(LocalVoices.label) ?? "system default")")
    }

    func say(_ text: String) async {
        stop()
        generation += 1
        let id = generation
        busy = true
        defer { if generation == id { busy = false } }

        if settings.serverVoiceEnabled {
            if let wav = await serverAudio(for: text) {
                guard generation == id, !Task.isCancelled else { return }
                if await play(wav, text: text) { return }
            } else {
                log.log("TTS: using on-device voice")
            }
        }
        guard generation == id, !Task.isCancelled else { return }
        await speakLocally(text)
    }

    /// Stops any speech immediately and resumes the pending `say`.
    func stop() {
        generation += 1
        busy = false
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        player?.stop()
        player = nil
        utterance = nil
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    // MARK: Server voice

    private func cacheKey(_ text: String) -> String {
        "\(settings.serverVoice)|\(text)"
    }

    /// Starts fetching `text` from the server voice without playing it, so that a later `say` of the
    /// same text finds it cached (or joins the request still running). Failures are only logged;
    /// `say` then retries and falls back to the on-device voice.
    func prefetch(_ text: String) {
        guard settings.serverVoiceEnabled, cache[cacheKey(text)] == nil else { return }
        _ = startFetch(text)
    }

    private func serverAudio(for text: String) async -> Data? {
        if let hit = cache[cacheKey(text)] {
            log.log("TTS server voice \(voiceName): cache hit")
            return hit
        }
        return await startFetch(text).value
    }

    /// The request for `text`, shared with any `prefetch` or `say` already running for it.
    private func startFetch(_ text: String) -> Task<Data?, Never> {
        let key = cacheKey(text)
        if let running = inflight[key] { return running }
        let voice = settings.serverVoice
        let task = Task { await self.fetchServerAudio(text, voice: voice, key: key) }
        inflight[key] = task
        return task
    }

    private var voiceName: String {
        settings.serverVoice.isEmpty ? "server default" : settings.serverVoice
    }

    private func fetchServerAudio(_ text: String, voice: String, key: String) async -> Data? {
        defer { inflight[key] = nil }
        let name = voice.isEmpty ? "server default" : voice
        let started = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        do {
            let api = try settings.makeAPI(log: log)
            let data = try await api.tts(text: text, voice: voice.isEmpty ? nil : voice, timeout: Self.serverTimeout)
            guard !data.isEmpty else { throw APIError.invalidResponse("empty audio") }
            log.log("TTS server voice \(name): \(elapsed()) ms, \(data.count / 1024) KB")
            if cache.count >= Self.cacheLimit { cache.removeAll() }
            cache[key] = data
            return data
        } catch {
            log.log("TTS server voice \(name) failed after \(elapsed()) ms (\(error.localizedDescription))")
            return nil
        }
    }

    /// Plays WAV data to the end. Returns false when it could not be played (caller falls back).
    private func play(_ wav: Data, text: String) async -> Bool {
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: wav)
        } catch {
            log.log("TTS server audio could not be decoded (\(error.localizedDescription)); using on-device voice")
            cache[cacheKey(text)] = nil
            return false
        }
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else {
            log.log("TTS server audio failed to start playing; using on-device voice")
            return false
        }
        log.log("TTS playing server audio (\(String(format: "%.1f", player.duration)) s): \(text)")
        self.player = player
        let limit = player.duration + 5
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled, let self, self.player === player else { return }
            self.log.log("TTS watchdog: audio did not finish after \(Int(limit)) s, stopping")
            self.stop()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
        watchdog.cancel()
        return true
    }

    private func playbackEnded(_ ended: AVAudioPlayer, success: Bool) {
        guard ended === player else { return }
        if !success { log.log("TTS server audio playback ended with an error") }
        player = nil
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.playbackEnded(player, success: flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.playbackEnded(player, success: false) }
    }

    // MARK: On-device voice

    private func speakLocally(_ text: String) async {
        let voice = LocalVoices.resolve(id: settings.localVoiceID)
        log.log("TTS on-device voice \(voice.map(LocalVoices.label) ?? "system default"): \(text)")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9

        // If the synthesizer never reports completion (e.g. after an audio interruption), do not hang forever.
        let limit = max(10, Double(text.count) * 0.2)
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled, let self, self.utterance === utterance else { return }
            self.log.log("TTS watchdog: no completion after \(Int(limit)) s, stopping")
            self.stop()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.utterance = utterance
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
        watchdog.cancel()
    }

    private func utteranceEnded(_ ended: AVSpeechUtterance) {
        guard ended === utterance else { return }
        utterance = nil
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.utteranceEnded(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.utteranceEnded(utterance) }
    }
}
