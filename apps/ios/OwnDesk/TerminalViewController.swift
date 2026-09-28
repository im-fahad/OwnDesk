import OwnDeskControllerCore
import OwnDeskTerminal
import SwiftTerm
import SwiftUI
import UIKit

/// The terminal screen, presented full screen by the home screen.
struct TerminalScreen: UIViewControllerRepresentable {
    @Environment(AppModel.self) private var model
    let target: TerminalTarget

    func makeUIViewController(context: Context) -> TerminalViewController {
        TerminalViewController(target: target, model: model)
    }

    func updateUIViewController(_ controller: TerminalViewController, context: Context) {}
}

/// A shell on a Mac, drawn by SwiftTerm and carried by SSH.
///
/// Everything is the Mac's: its SSH server checks who this is, its shell runs what is typed. This
/// screen only draws what comes back, sends the keys, and says what went wrong in words that say what
/// to do about it. SwiftTerm's own key bar gives Escape, Control, Tab and the arrows.
final class TerminalViewController: UIViewController, TerminalViewDelegate {
    private let target: TerminalTarget
    private weak var model: AppModel?
    private var ssh: SSHTerminal?
    private var events: Task<Void, Never>?
    private var attempt: Task<Void, Never>?
    private var exitStatus: Int?
    private var started = false
    private var closing = false

    private let header = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
    private let card = UIStackView()
    private let cardMessage = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let reconnectButton = UIButton(configuration: .filled())

    init(target: TerminalTarget, model: AppModel) {
        self.target = target
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Life cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(hex: 0x1F1F1F)
        buildLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Connect once the terminal has its real size, so the shell starts with the right one.
        guard !started, terminalView.bounds.width > 100 else { return }
        started = true
        connect()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        attempt?.cancel()
        events?.cancel()
        ssh?.close()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: Layout

    private func buildLayout() {
        header.backgroundColor = UIColor(hex: 0x1B1B1B)
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        var close = UIButton.Configuration.plain()
        close.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        close.baseForegroundColor = UIColor(Theme.textDim)
        let closeButton = UIButton(configuration: close, primaryAction: UIAction { [weak self] _ in self?.close() })
        closeButton.accessibilityLabel = "Close the terminal"
        closeButton.accessibilityIdentifier = "terminal-close"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(closeButton)

        titleLabel.text = target.peer.name
        titleLabel.font = .systemFont(ofSize: Theme.ui, weight: .semibold)
        titleLabel.textColor = UIColor(Theme.text)
        subtitleLabel.text = "\(target.settings.username) · terminal"
        subtitleLabel.font = .monospacedSystemFont(ofSize: Theme.section, weight: .regular)
        subtitleLabel.textColor = UIColor(Theme.textFaint)
        subtitleLabel.accessibilityIdentifier = "terminal-subtitle"
        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.alignment = .center
        titles.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titles)

        let divider = UIView()
        divider.backgroundColor = UIColor(Theme.border)
        divider.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(divider)

        terminalView.terminalDelegate = self
        terminalView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        terminalView.nativeBackgroundColor = UIColor(hex: 0x1F1F1F)
        terminalView.nativeForegroundColor = UIColor(hex: 0xD4D4D4)
        terminalView.accessibilityIdentifier = "terminal-view"
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        // A card over the terminal while connecting, and when it has ended.
        card.axis = .vertical
        card.spacing = 12
        card.alignment = .center
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)
        card.backgroundColor = UIColor(hex: 0x1A1A1A, alpha: 0.96)
        card.layer.cornerRadius = 10
        card.layer.borderColor = UIColor(Theme.border).cgColor
        card.layer.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        cardMessage.font = .systemFont(ofSize: Theme.ui)
        cardMessage.textColor = UIColor(Theme.text)
        cardMessage.numberOfLines = 0
        cardMessage.textAlignment = .center
        cardMessage.accessibilityIdentifier = "terminal-message"
        spinner.color = UIColor(Theme.textDim)
        reconnectButton.configuration?.title = "Reconnect"
        reconnectButton.configuration?.baseBackgroundColor = UIColor(Theme.accent)
        reconnectButton.accessibilityIdentifier = "terminal-reconnect"
        reconnectButton.addAction(UIAction { [weak self] _ in self?.connect() }, for: .primaryActionTriggered)
        [spinner, cardMessage, reconnectButton].forEach(card.addArrangedSubview)
        view.addSubview(card)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.bottomAnchor.constraint(equalTo: safe.topAnchor, constant: 48),
            closeButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 6),
            closeButton.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 40),
            titles.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titles.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titles.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            terminalView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            terminalView.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 4),
            terminalView.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -4),
            terminalView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: terminalView.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, multiplier: 0.86),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    private func showCard(_ message: String, busy: Bool) {
        cardMessage.text = message
        card.isHidden = false
        spinner.isHidden = !busy
        busy ? spinner.startAnimating() : spinner.stopAnimating()
        reconnectButton.isHidden = busy
    }

    // MARK: Connection

    private func connect() {
        attempt?.cancel()
        events?.cancel()
        ssh?.close()
        ssh = nil
        exitStatus = nil
        let settings = target.settings
        let name = target.peer.name
        showCard("Connecting to \(name)…", busy: true)

        attempt = Task { [weak self] in
            guard let self, let model = self.model else { return }
            // All probed at once, then tried one by one in order, where the Mac is now first. A
            // router that moves its leases can hand an old address of this Mac to another Mac, and
            // both answer on the SSH port.
            let urls = self.target.hosts.compactMap { Endpoints.url(host: $0, port: UInt16(clamping: settings.port)) }
            let reachable = await Endpoints.reachable(urls)
            guard !reachable.isEmpty else {
                self.ended("Nothing answered on port \(settings.port) of \(name). Turn on Remote Login there: System Settings → General → Sharing → Remote Login.")
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
                        host: host, port: settings.port, username: settings.username, key: model.sshKey,
                        password: { [weak self] in await self?.askPassword() },
                        hostKey: { [weak self] key in await self?.trust(key, seen: seen) ?? false },
                        options: .init(columns: terminal.cols, rows: terminal.rows))
                } catch SSHTerminalError.hostKeyRejected where seen.changed != nil {
                    // Not this Mac's key: another machine at an address this one used to have.
                    changedFingerprint = changedFingerprint ?? seen.changed
                    model.note("\(host) presented a different SSH key than \(name)'s; trying its next address")
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
                self.card.isHidden = true
                self.spinner.stopAnimating()
                _ = self.terminalView.becomeFirstResponder()
                model.note("terminal open on \(name) at \(host):\(settings.port)")
                return
            }
            if let changedFingerprint {
                _ = await self.ask(
                    title: "\(name)'s SSH key has changed",
                    message: "It now presents \(changedFingerprint), not the key this \(AppModel.deviceKind) saved, so the connection was refused: this is what someone in the middle would look like. If the Mac's key really changed, for example after reinstalling macOS, forget the old key in Terminal settings.",
                    yes: nil, identifier: "host-changed")
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
            guard card.isHidden else { return }
            let how = exitStatus.map { $0 == 0 ? "The shell on \(target.peer.name) ended." : "The shell on \(target.peer.name) ended with status \($0)." }
            ended(how ?? "The connection to \(target.peer.name) closed.")
        }
    }

    private func ended(_ message: String) {
        guard !closing else { return }
        _ = terminalView.resignFirstResponder()
        showCard(message, busy: false)
        model?.note(message)
    }

    private func close() {
        closing = true
        attempt?.cancel()
        ssh?.close()
        model?.terminalEnded(target)
    }

    private func describe(_ error: SSHTerminalError) -> String {
        let name = target.peer.name
        switch error {
        case .unreachable:
            return "Nothing answered on port \(target.settings.port) of \(name). Turn on Remote Login there: System Settings → General → Sharing → Remote Login."
        case .hostKeyRejected:
            return "Not connected: \(name)'s SSH key was not trusted."
        case .authenticationFailed:
            return "\(name) refused the login as \(target.settings.username). Check the user name, and add this \(AppModel.deviceKind)'s key on the Mac: touch and hold \(name) and choose Terminal settings."
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
        guard let model else { return false }
        let name = target.peer.name
        switch model.knownHosts.verdict(for: key, of: target.peer.deviceId) {
        case .known:
            return true
        case .new(let fingerprint):
            let path = "/etc/ssh/ssh_host_\(key.type.replacingOccurrences(of: "ssh-", with: "").replacingOccurrences(of: "ecdsa-sha2-nistp256", with: "ecdsa"))_key.pub"
            let yes = await ask(
                title: "Trust \(name)?",
                message: "This is the first terminal on \(name) from this \(AppModel.deviceKind). Its SSH key is\n\n\(key.type)\n\(fingerprint)\n\nOn the Mac, ssh-keygen -lf \(path) shows the same if it is that Mac.",
                yes: "Trust", identifier: "trust-host")
            if yes { model.knownHosts.pin(key, for: target.peer.deviceId) }
            return yes
        case .changed(let fingerprint):
            // Refused without a question. Whether to warn is decided once every address has been
            // tried: at an old address this is usually just another Mac.
            seen.changed = fingerprint
            return false
        }
    }

    private func askPassword() async -> String? {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "Password for \(target.settings.username)",
                message: "\(target.peer.name) did not take this \(AppModel.deviceKind)'s key. Type the account's password, or add the key there to skip this next time.",
                preferredStyle: .alert)
            alert.addTextField { field in
                field.isSecureTextEntry = true
                field.textContentType = .password
                field.accessibilityIdentifier = "ssh-password"
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: nil) })
            alert.addAction(UIAlertAction(title: "Log In", style: .default) { [weak alert] _ in
                continuation.resume(returning: alert?.textFields?.first?.text)
            })
            present(alert, animated: true)
        }
    }

    /// An alert with a yes and a no, or with only OK when `yes` is nil.
    private func ask(title: String, message: String, yes: String?, identifier: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.view.accessibilityIdentifier = identifier
            if let yes {
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: false) })
                alert.addAction(UIAlertAction(title: yes, style: .default) { _ in continuation.resume(returning: true) })
            } else {
                alert.addAction(UIAlertAction(title: "OK", style: .cancel) { _ in continuation.resume(returning: false) })
            }
            present(alert, animated: true)
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
        subtitleLabel.text = title.isEmpty ? "\(target.settings.username) · terminal" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) {
            UIApplication.shared.open(url)
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// A program on the Mac asked to copy something (OSC 52), such as a selection in tmux or vim.
    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }
}

/// The key a connection was refused for, when it was not the pinned one.
final class PresentedKey: @unchecked Sendable {
    var changed: String?
}
