import SwiftUI

@main
struct VoiceChessApp: App {
    @StateObject private var controller = GameController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
    }
}
