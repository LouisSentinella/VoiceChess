import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

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
                    Toggle("Confirm before playing", isOn: $settings.confirmBeforePlay)
                    Toggle("Hands-free", isOn: $settings.handsFree)
                    Toggle("Keep screen awake", isOn: $settings.keepAwake)
                } header: {
                    Text("Play")
                } footer: {
                    Text("Hands-free listens again automatically after every spoken reply. Otherwise use the talk button.")
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
        }
        .preferredColorScheme(.dark)
    }
}
