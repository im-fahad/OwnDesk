import PRCControllerCore
import SwiftUI

@main
struct ControllerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("PRC Controller") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
