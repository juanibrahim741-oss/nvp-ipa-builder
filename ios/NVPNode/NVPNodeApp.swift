import SwiftUI

@main
struct NVPNodeApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
            // Follows the system light/dark appearance.
        }
    }
}
