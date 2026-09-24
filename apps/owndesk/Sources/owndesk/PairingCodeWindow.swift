import AppKit
import SwiftUI

/// The pairing code as large as the screen allows, for a phone camera that cannot read the one in
/// the sheet: some focus poorly up close, and a bigger code can be read from further back.
///
/// Click anywhere or press Esc to close it. It also closes by itself when a pairing request arrives,
/// so it never hides the fingerprint to compare and the Approve button, and when the code expires or
/// is cancelled.
enum PairingCodeWindow {
    private static var window: NSWindow?

    static var isShown: Bool { window != nil }

    static func show(image: NSImage, fingerprint: String) {
        close()
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let window = CodeWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        // Above the main window and its sheet, which stay where they are underneath.
        window.level = .modalPanel
        window.backgroundColor = .white
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: FullScreenCode(image: image, fingerprint: fingerprint, close: close))
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    static func close() {
        window?.orderOut(nil)
        window = nil
    }

    /// Borderless windows refuse to become key unless told otherwise, and Esc needs a key window.
    private final class CodeWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { PairingCodeWindow.close() }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { PairingCodeWindow.close() } else { super.keyDown(with: event) }
        }
    }
}

private struct FullScreenCode: View {
    let image: NSImage
    let fingerprint: String
    let close: () -> Void

    var body: some View {
        GeometryReader { geometry in
            // White all round is the quiet zone a QR needs; the text below keeps its own room.
            let side = max(200, min(geometry.size.width, geometry.size.height - 150) * 0.9)
            VStack(spacing: 18) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: side, height: side)
                HStack(spacing: 12) {
                    Text("This Mac's fingerprint").foregroundStyle(Color(white: 0.4))
                    Text(fingerprint).font(.system(size: 22, design: .monospaced)).foregroundStyle(.black)
                }
                Text("Scan it from further back than usual. Click anywhere or press Esc to close.")
                    .foregroundStyle(Color(white: 0.4))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.white)
        .contentShape(Rectangle())
        .onTapGesture { close() }
    }
}
