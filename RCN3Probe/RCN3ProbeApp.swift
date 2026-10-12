import SwiftUI

/// App entry point. `@main` marks where the process starts (like the script tag that boots a SPA).
@main
struct RCN3ProbeApp: App {
    // `@State` keeps one model instance alive for the app's lifetime, much like a root store.
    @State private var model = ProbeModel()
    // The scene phase (active / inactive / background) works like the page Visibility API.
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}
