import SwiftUI

@main
struct VoiceAgentApp: App {
    @StateObject private var model = VoiceAgentModel()

    init() {
        // `swift run` starts this GUI process from Terminal. Explicit activation
        // ensures keyboard input goes to the app window instead of the shell.
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("Agent Chats") {
            ContentView(model: model)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
    }
}
