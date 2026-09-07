import PRCAgentCore
import SwiftUI

/// The Mac Mini's menu bar app (spec section 19). No Dock icon; everything lives in the menu bar panel
/// and a pairing window.
@main
struct AgentApp: App {
    @StateObject private var model = AgentAppModel()

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
