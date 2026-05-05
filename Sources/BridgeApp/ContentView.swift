import SwiftUI
import BridgeCore

struct ContentView: View {
    @EnvironmentObject var engine: BridgeEngine
    @EnvironmentObject var config: BridgeConfig

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "antenna.radiowaves.left.and.right") }

            ConfigView(config: config)
                .tabItem { Label("Settings", systemImage: "gear") }

            ModeMappingsView()
                .tabItem { Label("Modes", systemImage: "waveform") }

            LogView()
                .tabItem { Label("Log", systemImage: "doc.text") }
        }
        .padding()
    }
}
