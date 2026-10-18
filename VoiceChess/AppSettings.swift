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
        static let handsFree = "handsFree"
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
    @Published var handsFree: Bool {
        didSet { UserDefaults.standard.set(handsFree, forKey: Key.handsFree) }
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
        handsFree = defaults.object(forKey: Key.handsFree) as? Bool ?? false
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
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }
}
