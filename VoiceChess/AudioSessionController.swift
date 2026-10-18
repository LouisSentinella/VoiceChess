import AVFoundation

/// Owns the shared AVAudioSession: configuration for talking over Bluetooth/car audio,
/// plus interruption, route-change and media-services-reset handling (all logged).
@MainActor
final class AudioSessionController {
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?

    private let log: DebugLog
    private var hasLoggedActivation = false

    init(log: DebugLog) {
        self.log = log
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            Task { @MainActor in self?.handleInterruption(type: type, options: options, reason: reason) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            let previousText = previous.map(AudioSessionController.describe) ?? "?"
            Task { @MainActor in self?.handleRouteChange(reason: reason, previous: previousText) }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        }
    }

    /// Configures the category and activates the session. Call before listening or speaking.
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true)
        if !hasLoggedActivation {
            hasLoggedActivation = true
            log.log("Audio session active: \(session.category.rawValue)/\(session.mode.rawValue), \(Int(session.sampleRate)) Hz, \(Self.describe(session.currentRoute))")
        }
    }

    var routeDescription: String {
        Self.describe(AVAudioSession.sharedInstance().currentRoute)
    }

    nonisolated static func describe(_ route: AVAudioSessionRouteDescription) -> String {
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        return "in[\(inputs)] out[\(outputs)]"
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType?, options: UInt, reason: UInt?) {
        switch type {
        case .began:
            log.log("Audio interruption began (reason \(reason.map(String.init) ?? "?"))")
            onInterruptionBegan?()
        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            log.log("Audio interruption ended (shouldResume: \(shouldResume))")
            do {
                try activate()
                log.log("Audio session reactivated after interruption: \(routeDescription)")
            } catch {
                log.log("Audio session reactivation failed: \(error.localizedDescription)")
            }
            onInterruptionEnded?(shouldResume)
        default:
            log.log("Audio interruption: unknown type")
        }
    }

    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason?, previous: String) {
        let name: String
        switch reason {
        case .newDeviceAvailable: name = "new device available"
        case .oldDeviceUnavailable: name = "old device unavailable"
        case .categoryChange: name = "category change"
        case .override: name = "override"
        case .wakeFromSleep: name = "wake from sleep"
        case .noSuitableRouteForCategory: name = "no suitable route for category"
        case .routeConfigurationChange: name = "route configuration change"
        default: name = "unknown"
        }
        log.log("Route change: \(name); was \(previous); now \(routeDescription)")
    }

    private func handleMediaServicesReset() {
        log.log("Media services were reset; reconfiguring audio session")
        hasLoggedActivation = false
        do {
            try activate()
        } catch {
            log.log("Audio session reconfiguration failed: \(error.localizedDescription)")
        }
    }
}
