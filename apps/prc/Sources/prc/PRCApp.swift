import AppKit
import PRCAgentCore
import SwiftUI

/// One app for both roles. It lives in the menu bar so a Mac started at login is reachable without
/// a window, and opens a window when you want to control something.
@main
struct PRCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState(config: AppConfiguration.fromCommandLine())

    var body: some Scene {
        Window("PRC", id: PRCApp.windowID) {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 880, minHeight: 560)

        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .sidebar) {
                // These reach the app only when the pointer is off the video: while it is over the
                // stream every key belongs to the Mac being controlled.
                Button("Toggle Peers") { state.showSidebar.toggle() }.keyboardShortcut("b", modifiers: .command)
                Button("Toggle Log") { state.showLog.toggle() }.keyboardShortcut("j", modifiers: .command)
                Divider()
                Button(state.isConnected ? "Disconnect" : "Connect") {
                    state.isConnected ? state.disconnect() : state.connect()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarPanel().environmentObject(state)
        } label: {
            Image(systemName: state.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }

    static let windowID = "prc.main"
}

extension Notification.Name {
    static let prcOpenWindow = Notification.Name("prc.openWindow")
}

/// Starts as an accessory so the copy launchd runs at login adds no Dock icon, and becomes a normal
/// app while a window is open so it can take keyboard focus properly.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy should serve a Mac: a second would advertise the same identity twice.
        AppDelegate.exitIfAlreadyRunning()
        let background = AppConfiguration.fromCommandLine().background
        // Accessory suppresses the window entirely, which is what the login copy wants and what a
        // person opening the app does not.
        // Decided once and never changed. Changing it later leaves the Metal-backed video view
        // showing black: frames still decode and the renderer still reports their size, but nothing
        // is drawn. The login copy stays an accessory so it adds no Dock icon; a copy someone opens
        // behaves like a normal app.
        NSApp.setActivationPolicy(background ? .accessory : .regular)
        guard background else { return }
        // Hidden, not closed. Closing destroys the scene's views, and the Metal-backed video view
        // SwiftUI builds for a replacement window renders black. Ordering it out keeps the one made
        // at launch, which works, and showing it again is just ordering it back in.
        DispatchQueue.main.async {
            for window in NSApp.windows where !window.className.contains("MenuBarExtra") {
                window.orderOut(nil)
            }
        }
    }

    static func exitIfAlreadyRunning() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return }
        others.first?.activate()
        exit(0)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the app again, from Finder or the Dock, should show the window rather than do nothing.
    /// The app is usually an accessory with its window closed, so there is nothing for AppKit to raise.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, !AppDelegate.showExistingWindow() {
            NotificationCenter.default.post(name: .prcOpenWindow, object: nil)
        }
        return true
    }

    /// Must run *before* the window is built. Changing the activation policy after a Metal-backed
    /// video view exists leaves it showing black: frames still decode and the renderer still reports
    /// their size, but nothing is drawn.
    /// Brings the app forward and shows the window it built at launch. Returns true when it found
    /// one, so callers know not to ask SwiftUI for a new one.
    @discardableResult
    static func showExistingWindow() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: { !$0.className.contains("MenuBarExtra") && $0.contentView != nil }) else {
            return false
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

extension AppState {
    var menuIcon: String {
        if incoming?.path != nil { return "display.and.arrow.down" }
        if isConnected { return "display" }
        if hosting { return "display" }
        return "display.trianglebadge.exclamationmark"
    }
}
