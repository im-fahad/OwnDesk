import PRCControllerCore
import SwiftUI

@main
struct ControllerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("PRC Controller") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .sidebar) {
                // These only reach the menu when the pointer is off the video: while it is over the
                // stream every key belongs to the host, deliberately.
                Button("Toggle Hosts") { model.showSidebar.toggle() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Toggle Log") { model.showLog.toggle() }
                    .keyboardShortcut("j", modifiers: .command)
                Divider()
                Button(model.isConnected ? "Disconnect" : "Connect") {
                    model.isConnected ? model.disconnect() : model.connect()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}
