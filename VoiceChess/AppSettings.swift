import SwiftUI
import VoiceChessCore

/// User preferences persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let defaultServerURL = "https://louis-desktop.tail4f111a.ts.net"
    static let maiaLevels = Array(stride(from: 1100, through: 1900, by: 100))

    private enum Key {
        static let serverURL = "serverURL"
        static let confirmBeforePlay = "confirmBeforePlay"
        static let legacyHandsFree = "handsFree"
        static let autoListen = "autoListen"
        static let serverVoiceEnabled = "serverVoiceEnabled"
        static let serverVoice = "serverVoice"
        static let localVoiceID = "localVoiceID"
        static let keepAwake = "keepAwake"
        static let side = "side"
        static let maiaLevel = "maiaLevel"
    }

    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Key.serverURL) }
    }
    @Published var confirmBeforePlay: Bool {
        didSet { UserDefaults.standard.set(confirmBeforePlay, forKey: Key.confirmBeforePlay) }
    }
    /// Listen again automatically after every move until the game ends or the user pauses.
    @Published var autoListen: Bool {
        didSet { UserDefaults.standard.set(autoListen, forKey: Key.autoListen) }
    }
    /// Speak through the server's /tts endpoint, falling back to the on-device voice.
    @Published var serverVoiceEnabled: Bool {
        didSet { UserDefaults.standard.set(serverVoiceEnabled, forKey: Key.serverVoiceEnabled) }
    }
    /// Server voice name; empty means the server's default.
    @Published var serverVoice: String {
        didSet { UserDefaults.standard.set(serverVoice, forKey: Key.serverVoice) }
    }
    /// AVSpeechSynthesisVoice identifier for the offline fallback; empty means the best installed.
    @Published var localVoiceID: String {
        didSet { UserDefaults.standard.set(localVoiceID, forKey: Key.localVoiceID) }
    }
    @Published var keepAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: Key.keepAwake)
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
    }
    @Published var side: SidePreference {
        didSet { UserDefaults.standard.set(side.rawValue, forKey: Key.side) }
    }
    @Published var maiaLevel: Int {
        didSet { UserDefaults.standard.set(maiaLevel, forKey: Key.maiaLevel) }
    }

    init() {
        let defaults = UserDefaults.standard
        serverURL = defaults.string(forKey: Key.serverURL) ?? Self.defaultServerURL
        confirmBeforePlay = defaults.object(forKey: Key.confirmBeforePlay) as? Bool ?? false
        // The old hands-free toggle is replaced by auto-listen, which starts ON for everyone.
        defaults.removeObject(forKey: Key.legacyHandsFree)
        autoListen = defaults.object(forKey: Key.autoListen) as? Bool ?? true
        serverVoiceEnabled = defaults.object(forKey: Key.serverVoiceEnabled) as? Bool ?? true
        serverVoice = defaults.string(forKey: Key.serverVoice) ?? ""
        localVoiceID = defaults.string(forKey: Key.localVoiceID) ?? ""
        keepAwake = defaults.object(forKey: Key.keepAwake) as? Bool ?? true
        side = SidePreference(rawValue: defaults.string(forKey: Key.side) ?? "") ?? .random
        let level = defaults.integer(forKey: Key.maiaLevel)
        maiaLevel = Self.maiaLevels.contains(level) ? level : 1500
        UIApplication.shared.isIdleTimerDisabled = keepAwake
    }

    /// The configured server URL, or nil if it is not a usable http(s) URL.
    var baseURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    /// An API client for the configured server; HTTP calls are logged to `log`.
    func makeAPI(log: DebugLog) throws -> APIClient {
        guard let url = baseURL else { throw APIError.unreachable("invalid server URL") }
        return APIClient(baseURL: url, log: { line in Task { @MainActor in log.log(line) } })
    }
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }
}
