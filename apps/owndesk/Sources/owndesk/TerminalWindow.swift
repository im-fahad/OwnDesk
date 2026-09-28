import AppKit
import OwnDeskControllerCore
import OwnDeskPeers
import OwnDeskTerminal
import SwiftTerm
import SwiftUI

/// A window that holds a terminal, so the app can tell it apart from its main window: the main
/// window is put away rather than closed, while a terminal closes for good and ends its shell.
final class TerminalWindow: NSWindow {}

/// A shell on another Mac, in a window of its own. SwiftTerm draws it and SSH carries it.
///
/// Everything is the other Mac's: its SSH server checks who this is, its shell runs what is typed.
/// This window only draws what comes back, sends the keys, and says what went wrong in words that say
/// what to do about it. Several can be open at once, on the same Mac or on different ones.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate, TerminalViewDelegate {
    /// Every open terminal, which is what keeps each controller alive while its window is up.
    /// Only ever touched on the main thread, from window callbacks and the app delegate.
    nonisolated(unsafe) private(set) static var open: [TerminalWindowController] = []
    private static var cascadePoint = NSPoint.zero

    private let peer: Peer
    private let settings: TerminalSettings
    private weak var state: AppState?
    private var ssh: SSHTerminal?
    private var events: Task<Void, Never>?
    private var attempt: Task<Void, Never>?
    private var exitStatus: Int?
    private var connected = false
    private var closing = false

    private let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
    private var card: NSHostingView<TerminalCard>?
    private var cardMessage = ""
    private var cardBusy = true

    static func open(_ peer: Peer, settings: TerminalSettings, state: AppState) {
        let controller = TerminalWindowController(peer: peer, settings: settings, state: state)
        open.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.connect()
    }

    private init(peer: Peer, settings: TerminalSettings, state: AppState) {
        self.peer = peer
        self.settings = settings
        self.state = state
        let window = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.title = "\(peer.name) — \(settings.username)"
        window.subtitle = "terminal"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(hex: 0x1F1F1F)
        window.minSize = NSSize(width: 420, height: 260)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)
        window.contentView = buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    private func buildContent() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        container.autoresizesSubviews = true

        terminalView.terminalDelegate = self
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeBackgroundColor = NSColor(hex: 0x1F1F1F)
        terminalView.nativeForegroundColor = NSColor(hex: 0xD4D4D4)
        terminalView.caretColor = NSColor(hex: 0x4D8EF7)
        terminalView.frame = container.bounds.insetBy(dx: 4, dy: 4)
        terminalView.autoresizingMask = [.width, .height]
        container.addSubview(terminalView)

        // A card over the terminal while connecting, and when the shell has ended.
        let card = NSHostingView(rootView: makeCard())
        card.frame = container.bounds
        card.autoresizingMask = [.width, .height]
        container.addSubview(card)
        self.card = card
        return container
    }

    private func makeCard() -> TerminalCard {
        TerminalCard(message: cardMessage, busy: cardBusy,
                     reconnect: { [weak self] in self?.connect() },
                     close: { [weak self] in self?.window?.performClose(nil) })
    }

    private func showCard(_ message: String, busy: Bool) {
        cardMessage = message
        cardBusy = busy
        card?.rootView = makeCard()
        card?.isHidden = false
    }

    private func hideCard() {
        card?.isHidden = true
    }

    // MARK: Connection

    private func connect() {
        attempt?.cancel()
        events?.cancel()
        ssh?.close()
        ssh = nil
        exitStatus = nil
        connected = false
        let name = peer.name
        showCard("Connecting to \(name)…", busy: true)

        attempt = Task { [weak self] in
            guard let self, let state = self.state else { return }
            // Where the Mac advertises itself now comes first, then every address it was known by.
            let hosts = await state.terminalHosts(for: self.peer)
            let port = UInt16(clamping: self.settings.port)
            let urls = hosts.compactMap { Endpoints.url(host: $0, port: port) }
            guard !urls.isEmpty else {
                self.ended("No address is known for \(name). Connect to its screen once, or pair again, and try the terminal after.")
                return
            }
            // All probed at once, then tried one by one in that order. A router that moves its
            // leases can hand an old address of this Mac to another Mac, and both answer on port 22.
            let reachable = await Endpoints.reachable(urls)
            guard !reachable.isEmpty else {
                self.ended(self.describe(.unreachable("")))
                return
            }
            let terminal = self.terminalView.getTerminal()
            var changedFingerprint: String?
            for url in reachable {
                guard let host = url.host, !Task.isCancelled else { return }
                let candidate = SSHTerminal()
                let seen = PresentedKey()
                do {
                    try await candidate.connect(
                        host: host, port: self.settings.port, username: self.settings.username, key: state.sshKey,
                        password: { [weak self] in await self?.askPassword() },
                        hostKey: { [weak self] key in await self?.trust(key, seen: seen) ?? false },
                        options: .init(columns: terminal.cols, rows: terminal.rows))
                } catch SSHTerminalError.hostKeyRejected where seen.changed != nil {
                    // Not this Mac's key: another machine at an address this one used to have.
                    changedFingerprint = changedFingerprint ?? seen.changed
                    state.append("\(host) presented a different SSH key than \(name)'s; trying its next address")
                    continue
                } catch let error as SSHTerminalError {
                    self.ended(self.describe(error))
                    return
                } catch {
                    self.ended("The connection to \(name) failed: \(error.localizedDescription)")
                    return
                }
                guard !Task.isCancelled else { candidate.close(); return }
                self.attach(candidate)
                self.connected = true
                self.hideCard()
                self.window?.makeFirstResponder(self.terminalView)
                state.append("terminal open on \(name) at \(host):\(self.settings.port)")
                return
            }
            // Every address answered with a key other than the pinned one.
            if let changedFingerprint {
                _ = await self.ask(
                    title: "\(name)'s SSH key has changed",
                    message: "It now presents \(changedFingerprint), not the key this Mac saved, so the connection was refused: this is what someone in the middle would look like. If the Mac's key really changed, for example after reinstalling macOS, forget the old key in Terminal settings.",
                    yes: nil)
                self.ended("Not connected: \(name)'s SSH key has changed. If it really did, forget the old key in Terminal settings.")
            }
        }
    }

    /// The shell is running on this connection: its output goes to the screen from now on. Events
    /// wait in the connection's stream until this starts reading them, so nothing is lost.
    private func attach(_ terminal: SSHTerminal) {
        ssh = terminal
        let stream = terminal.events
        events = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.handle(event, from: terminal)
            }
        }
    }

    private func handle(_ event: SSHTerminal.Event, from source: SSHTerminal) {
        guard source === ssh else { return }
        switch event {
        case .output(let bytes):
            terminalView.feed(byteArray: bytes[...])
        case .exitStatus(let code):
            exitStatus = code
        case .closed:
            guard connected else { return }
            connected = false
            let how = exitStatus.map { $0 == 0 ? "The shell on \(peer.name) ended." : "The shell on \(peer.name) ended with status \($0)." }
            ended(how ?? "The connection to \(peer.name) closed.")
        }
    }

    private func ended(_ message: String) {
        guard !closing else { return }
        showCard(message, busy: false)
        state?.append(message)
    }

    private func describe(_ error: SSHTerminalError) -> String {
        let name = peer.name
        switch error {
        case .unreachable:
            return "Nothing answered on port \(settings.port) of \(name). Turn on Remote Login there: System Settings → General → Sharing → Remote Login."
        case .hostKeyRejected:
            return "Not connected: \(name)'s SSH key was not trusted."
        case .authenticationFailed:
            return "\(name) refused the login as \(settings.username). Check the user name, and add this Mac's key on \(name): right-click it in the sidebar and choose Terminal settings."
        case .cancelled:
            return "Not connected: no password was given."
        case .shellRefused:
            return "\(name) accepted the login but would not start a shell."
        case .closed(let why):
            return "The connection to \(name) closed: \(why)"
        }
    }

    // MARK: Questions

    /// The first time, the person decides from the fingerprint; after that the key is pinned, and a
    /// different one is refused without a question, since that is what an interception looks like.
    private func trust(_ key: SSHHostKey, seen: PresentedKey) async -> Bool {
        guard let state else { return false }
        let name = peer.name
        switch state.knownHosts.verdict(for: key, of: peer.deviceId) {
        case .known:
            return true
        case .new(let fingerprint):
            let file = key.type.replacingOccurrences(of: "ssh-", with: "").replacingOccurrences(of: "ecdsa-sha2-nistp256", with: "ecdsa")
            let yes = await ask(
                title: "Trust \(name)?",
                message: "This is the first terminal on \(name) from this Mac. Its SSH key is\n\n\(key.type)\n\(fingerprint)\n\nOn \(name), ssh-keygen -lf /etc/ssh/ssh_host_\(file)_key.pub shows the same if it is that Mac.",
                yes: "Trust")
            if yes { state.knownHosts.pin(key, for: peer.deviceId) }
            return yes
        case .changed(let fingerprint):
            // Refused without a question. Whether to warn is decided once every address has been
            // tried: at an old address this is usually just another Mac.
            seen.changed = fingerprint
            return false
        }
    }

    private func askPassword() async -> String? {
        guard let window else { return nil }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "Password for \(settings.username) on \(peer.name)"
            alert.informativeText = "\(peer.name) did not take this Mac's key. Type the account's password, or add the key there to skip this next time."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = "password"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: "Log In")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                // A closing sheet does not hand keyboard focus back to its window by itself.
                window.makeKey()
                continuation.resume(returning: response == .alertFirstButtonReturn ? field.stringValue : nil)
            }
        }
    }

    /// A sheet with a yes and a no, or with only OK when `yes` is nil.
    private func ask(title: String, message: String, yes: String?) async -> Bool {
        guard let window else { return false }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: yes ?? "OK")
            if yes != nil { alert.addButton(withTitle: "Cancel") }
            alert.beginSheetModal(for: window) { response in
                window.makeKey()
                continuation.resume(returning: yes != nil && response == .alertFirstButtonReturn)
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        closing = true
        attempt?.cancel()
        events?.cancel()
        ssh?.close()
        Self.open.removeAll { $0 === self }
        state?.append("closed the terminal on \(peer.name)")
        // With no terminal left and the main window put away, the Dock icon has nothing to stand for.
        if Self.open.isEmpty, !AppDelegate.mainWindows.contains(where: \.isVisible) {
            AppDelegate.showDockIcon(false)
        }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        ssh?.send(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        ssh?.resize(columns: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        window?.subtitle = title.isEmpty ? "terminal" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// A program on the other Mac asked to copy something (OSC 52), such as a selection in tmux or vim.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The key a connection was refused for, when it was not the pinned one.
final class PresentedKey: @unchecked Sendable {
    var changed: String?
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// What the terminal shows while it is not a shell: connecting, or why it ended, with a way back.
struct TerminalCard: View {
    let message: String
    let busy: Bool
    let reconnect: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.clear
            VStack(spacing: 14) {
                if busy {
                    ProgressView().controlSize(.small)
                }
                Text(message)
                    .font(Theme.ui)
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if !busy {
                    HStack(spacing: 10) {
                        Button("Close") { close() }.buttonStyle(HeaderButtonStyle(tint: Theme.textDim))
                        Button("Reconnect") { reconnect() }.buttonStyle(HeaderButtonStyle(tint: Theme.accent))
                    }
                }
            }
            .padding(22)
            .frame(minWidth: 260, maxWidth: 460)
            .background(Theme.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        }
        .preferredColorScheme(.dark)
    }
}
