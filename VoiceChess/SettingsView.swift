import AVFoundation
import SwiftUI
import VoiceChessCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let controller: GameController
    @Environment(\.dismiss) private var dismiss
    @State private var serverVoices: [String] = []
    @State private var serverDefault: String?
    @State private var voiceProblem: String?
    private let localVoices = LocalVoices.installed()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Reset to default") { settings.serverURL = AppSettings.defaultServerURL }
                    if settings.baseURL == nil {
                        Text("Not a valid http(s) URL").foregroundStyle(.red)
                    }
                } header: {
                    Text("Server")
                }

                Section {
                    Toggle("Auto-listen", isOn: $settings.autoListen)
                    Toggle("Confirm before playing", isOn: $settings.confirmBeforePlay)
                    Toggle("Ask the coach", isOn: $settings.askCoach)
                    Toggle("Keep screen awake", isOn: $settings.keepAwake)
                } header: {
                    Text("Play")
                } footer: {
                    Text("Auto-listen listens again after every move until you tap Pause, and keeps listening for questions after the game ends. It pauses when the app goes to the background or audio is interrupted. With it off, use the Listen button for each move. Ask the coach sends questions such as \"why was that a mistake\" to the server and speaks the answer.")
                }

                Section {
                    Toggle("Server voice", isOn: $settings.serverVoiceEnabled)
                    if settings.serverVoiceEnabled {
                        Picker("Voice", selection: $settings.serverVoice) {
                            Text(serverDefault.map { "Server default (\($0))" } ?? "Server default").tag("")
                            ForEach(serverVoiceChoices, id: \.self) { Text($0).tag($0) }
                        }
                        if let voiceProblem {
                            Text(voiceProblem).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Offline voice", selection: $settings.localVoiceID) {
                        Text(automaticLocalLabel).tag("")
                        ForEach(localVoices, id: \.identifier) { voice in
                            Text(LocalVoices.label(voice)).tag(voice.identifier)
                        }
                    }
                    Button("Test voice") { controller.testVoice() }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("For a better offline voice download a Premium voice in iOS Settings > Accessibility > Spoken Content > Voices")
                }

                Section("About") {
                    LabeledContent("Version", value: AppInfo.version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: settings.serverVoiceEnabled) { await loadServerVoices() }
            .onAppear {
                if !settings.localVoiceID.isEmpty, !localVoices.contains(where: { $0.identifier == settings.localVoiceID }) {
                    settings.localVoiceID = ""
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// The server's voices, plus the stored choice if the server no longer lists it.
    private var serverVoiceChoices: [String] {
        var choices = serverVoices
        if !settings.serverVoice.isEmpty, !choices.contains(settings.serverVoice) { choices.append(settings.serverVoice) }
        return choices
    }

    private var automaticLocalLabel: String {
        guard let best = localVoices.first else { return "Automatic" }
        return "Automatic (\(best.name), \(LocalVoices.qualityLabel(best.quality)))"
    }

    private func loadServerVoices() async {
        guard settings.serverVoiceEnabled else { return }
        voiceProblem = nil
        do {
            let api = try settings.makeAPI(log: controller.log)
            let result = try await api.ttsVoices()
            serverVoices = result.voices
            serverDefault = result.defaultVoice
        } catch {
            serverVoices = []
            serverDefault = nil
            voiceProblem = "Could not load server voices: \(error.localizedDescription)"
        }
    }
}
