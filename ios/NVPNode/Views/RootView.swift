import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ZStack {
            // Subtle navy gradient backdrop.
            LinearGradient(
                colors: [Theme.bg, Theme.elev],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if app.isRegistered {
                TabView {
                    WorkerView()
                        .tabItem { Label("Worker", systemImage: "bolt.fill") }
                    NetworkView()
                        .tabItem { Label("Network", systemImage: "point.3.connected.trianglepath.dotted") }
                    EarningsView()
                        .tabItem { Label("Earnings", systemImage: "dollarsign.circle.fill") }
                    LogsView()
                        .tabItem { Label("Logs", systemImage: "text.alignleft") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                }
                .tint(Theme.gold)
            } else {
                OnboardingView()
            }
        }
    }
}
