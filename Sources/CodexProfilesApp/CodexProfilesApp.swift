import SwiftUI

@main
struct CodexProfilesApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Codex Profiles") {
            ContentView(model: model)
        }
        .defaultSize(width: 520, height: 430)
    }
}
