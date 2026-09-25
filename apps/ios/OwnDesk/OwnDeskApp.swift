import SwiftUI

/// The iPhone controller: the Macs this iPhone may control, and a full-screen session with one.
/// It controls and never hosts, like the Android app, and speaks the same signed protocol through
/// the Mac controller's own core (`OwnDeskControllerCore`), so there is no second implementation of
/// pairing, authentication or the session to keep in step.
@main
struct OwnDeskApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
