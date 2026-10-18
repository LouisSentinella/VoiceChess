import SwiftUI
import VoiceChessCore

struct NewGameView: View {
    @ObservedObject var settings: AppSettings
    let controller: GameController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Your side") {
                    Picker("Your side", selection: $settings.side) {
                        ForEach(SidePreference.allCases, id: \.self) { side in
                            Text(side.rawValue.capitalized).tag(side)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Maia level") {
                    Picker("Maia level", selection: $settings.maiaLevel) {
                        ForEach(AppSettings.maiaLevels, id: \.self) { level in
                            Text("\(level)").tag(level)
                        }
                    }
                    .pickerStyle(.wheel)
                }
                Section {
                    Button {
                        dismiss()
                        controller.newGame()
                    } label: {
                        Text("Start game")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                }
            }
            .navigationTitle("New Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}
