import SwiftUI
import BridgeCore

@main
struct RigRelayApp: App {

    @StateObject private var config = BridgeConfig()
    @StateObject private var engine: BridgeEngine

    init() {
        let c = BridgeConfig()
        _config = StateObject(wrappedValue: c)
        _engine = StateObject(wrappedValue: BridgeEngine(config: c))
    }

    var body: some Scene {
        WindowGroup("RigRelay") {
            ContentView()
                .environmentObject(config)
                .environmentObject(engine)
                .frame(minWidth: 720, minHeight: 580)
                .task {
                    if config.startAtLaunch {
                        await engine.start()
                    }
                }
        }
        .windowResizability(.contentSize)

        // macOS menu bar extra (macOS 13+)
        MenuBarExtra("RigRelay", systemImage: menuBarIcon) {
            MenuBarView()
                .environmentObject(config)
                .environmentObject(engine)
        }
    }

    private var menuBarIcon: String {
        // SF Symbol that changes with running state
        "antenna.radiowaves.left.and.right"
    }
}
