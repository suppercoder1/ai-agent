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
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 620, minHeight: 560)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)
    }
}
