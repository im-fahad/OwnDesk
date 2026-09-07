import AppKit
import PRCAgentCore
import SwiftUI

/// The Mac Mini's menu bar app (spec section 19). No Dock icon; everything lives in the menu bar panel
/// and a pairing window.
@main
struct AgentApp: App {
    @StateObject private var model = AgentAppModel()

    init() {
        AgentApp.exitIfAlreadyRunning()
    }

    /// One agent per user session. A second copy, for example the LaunchAgent's plus one opened from
    /// Finder, would load the same identity and advertise twice, splitting connections between them.
    static func exitIfAlreadyRunning() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return }
        others.first?.activate()
        exit(0)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView().environmentObject(model)
        } label: {
            Image(systemName: model.menuIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Pair New Device", id: "pairing") {
            PairingWindowView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}
