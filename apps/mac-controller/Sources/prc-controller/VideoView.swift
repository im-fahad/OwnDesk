import AppKit
import PRCControllerCore
import PRCProtocol
import SwiftUI
import WebRTC

/// The remote screen plus an input overlay. The overlay owns the keyboard while the pointer is over
/// the video and the window is key, so system shortcuts like Cmd+Q go to the host, not this app.
struct VideoView: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeNSView(context: Context) -> VideoContainerView {
        let view = VideoContainerView()
        view.onMessage = { [weak model] message in model?.send(message) }
        model.attach(renderer: view.renderer)
        return view
    }

    func updateNSView(_ nsView: VideoContainerView, context: Context) {}
}

final class VideoContainerView: NSView, RTCVideoViewDelegate {
    let renderer = RTCMTLNSVideoView(frame: .zero)
    private let overlay = InputCaptureView(frame: .zero)
    var onMessage: ((DataChannelMessage) -> Void)? {
        didSet { overlay.onMessage = onMessage }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        renderer.delegate = self
        renderer.autoresizingMask = [.width, .height]
        overlay.autoresizingMask = [.width, .height]
        addSubview(renderer)
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        renderer.frame = bounds
        overlay.frame = bounds
        overlay.geometry.viewSize = bounds.size
    }

    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        DispatchQueue.main.async { self.overlay.geometry.videoSize = size }
    }
}

/// Flipped so y grows downward like the protocol's normalized coordinates.
final class InputCaptureView: NSView {
    var geometry = VideoGeometry(viewSize: .zero, videoSize: .zero)
    var onMessage: ((DataChannelMessage) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var keyMonitor: Any?
    private var lastFlags: NSEvent.ModifierFlags = []
    private var displayId: String { "main" }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Mouse

    private func move(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let n = geometry.normalize(p) else { return }
        onMessage?(.mouseMove(displayId: displayId, x: n.x, y: n.y))
    }

    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func rightMouseDragged(with event: NSEvent) { move(event) }
    override func otherMouseDragged(with event: NSEvent) { move(event) }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); move(event); onMessage?(.mouseDown(.left)) }
    override func mouseUp(with event: NSEvent) { onMessage?(.mouseUp(.left)) }
    override func rightMouseDown(with event: NSEvent) { move(event); onMessage?(.mouseDown(.right)) }
    override func rightMouseUp(with event: NSEvent) { onMessage?(.mouseUp(.right)) }
    override func otherMouseDown(with event: NSEvent) { move(event); onMessage?(.mouseDown(.middle)) }
    override func otherMouseUp(with event: NSEvent) { onMessage?(.mouseUp(.middle)) }

    override func scrollWheel(with event: NSEvent) {
        onMessage?(MouseMap.scroll(from: event))
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeFirstResponder(self)
        installKeyMonitor()
        NSCursor.crosshair.push()
    }

    override func mouseExited(with event: NSEvent) {
        removeKeyMonitor()
        NSCursor.pop()
        releaseModifiers()
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            self.handleKey(event)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            guard let code = KeyMap.w3cCode(for: event.keyCode) else { return }
            onMessage?(.keyDown(code: code, modifiers: KeyMap.modifiers(from: event.modifierFlags), repeat: event.isARepeat))
        case .keyUp:
            guard let code = KeyMap.w3cCode(for: event.keyCode) else { return }
            onMessage?(.keyUp(code: code, modifiers: KeyMap.modifiers(from: event.modifierFlags)))
        case .flagsChanged:
            guard let code = KeyMap.w3cCode(for: event.keyCode), let flag = KeyMap.modifierFlag(forKeyCode: event.keyCode) else { return }
            let flags = event.modifierFlags
            let modifiers = KeyMap.modifiers(from: flags)
            if flags.contains(flag) && !lastFlags.contains(flag) {
                onMessage?(.keyDown(code: code, modifiers: modifiers, repeat: false))
            } else if !flags.contains(flag) && lastFlags.contains(flag) {
                onMessage?(.keyUp(code: code, modifiers: modifiers))
            }
            lastFlags = flags
        default:
            break
        }
    }

    /// Lift any modifier still held when the pointer leaves, so the host never sees a stuck Command key.
    private func releaseModifiers() {
        for (keyCode, flag) in [(UInt16(56), NSEvent.ModifierFlags.shift), (59, .control), (58, .option), (55, .command)] where lastFlags.contains(flag) {
            if let code = KeyMap.w3cCode(for: keyCode) { onMessage?(.keyUp(code: code, modifiers: [])) }
        }
        lastFlags = []
    }

    deinit { removeKeyMonitor() }
}
