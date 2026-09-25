import OwnDeskControllerCore
import OwnDeskPeers
import OwnDeskProtocol
import OwnDeskTouch
import SwiftUI
import UIKit
import WebRTC

/// The session screen, presented full screen by the home screen.
struct SessionScreen: UIViewControllerRepresentable {
    @Environment(AppModel.self) private var model
    let target: SessionTarget

    func makeUIViewController(context: Context) -> SessionViewController {
        SessionViewController(target: target, model: model)
    }

    func updateUIViewController(_ controller: SessionViewController, context: Context) {}
}

/// The Mac's screen, and the finger on it.
///
/// The same screen as the Android app's SessionActivity: the picture fitted to the display, a slim
/// sidebar on the black bar beside it, and the gestures in `Gestures`. Everything that talks to the
/// Mac is `SessionClient`, the Mac controller's own session state machine, so authentication,
/// negotiation, keepalive and reconnection behave exactly as they do from a MacBook.
final class SessionViewController: UIViewController {
    private static let trackpadSpeed = 1.5
    private static let maxZoom: CGFloat = 4

    private let target: SessionTarget
    private weak var model: AppModel?
    private let client: SessionClient
    /// Input goes out strictly in the order it happened: a key up must never overtake its key down.
    private let outbound = OrderedExecutor()
    private var events: Task<Void, Never>?
    private var connecting: Task<Void, Never>?

    private let videoView = RTCMTLVideoView(frame: .zero)
    private let surface = TouchSurface()
    private let statusLabel = PaddedLabel()
    private let captureBanner = PaddedLabel()
    private let holdMark = UIView()
    private let sidebar = UIStackView()
    private let infoPanel = UIStackView()
    private let infoContainer = UIView()
    private let keyboard = KeyboardCatcher()
    private var modeButton: UIButton!
    private var keyboardButton: UIButton!
    private var infoButton: UIButton!

    private let scheduler = MainQueueScheduler()
    private lazy var gestures = Gestures(output: self, scheduler: scheduler)

    private var display: DisplayInfo?
    private var frameSize: CGSize = .zero
    private var scale: CGFloat = 1
    private var panX: CGFloat = 0
    private var panY: CGFloat = 0
    private var lastMoveSent: Int64 = 0
    private var address: String?
    private var route: String?
    private var roundTripMs: Double?
    private var infoTimer: Timer?
    private var hideStatusWork: DispatchWorkItem?
    private var finished = false
    /// Where the sidebar sits: on the black bar beside the picture in landscape, and in a row under
    /// it in portrait, where the bars are above and below and a column would cover the picture. It is
    /// a row above the keyboard whenever the keyboard is open, since a column has no room there.
    private var besideConstraints: [NSLayoutConstraint] = []
    private var belowConstraints: [NSLayoutConstraint] = []
    private var inRow: Bool?

    init(target: SessionTarget, model: AppModel) {
        self.target = target
        self.model = model
        client = SessionClient(.init(identity: model.identity, host: target.peer, config: model.config))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Life cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildLayout()
        start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        // First responder so a hardware keyboard reaches the Mac even with the soft keyboard closed.
        becomeFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        if !finished {
            let client = self.client
            Task { await client.disconnect() }
            finish("disconnected")
        }
    }

    // With the soft keyboard closed, a hardware keyboard's keys arrive here, and every one of them
    // goes to the Mac as a key: there is no text field to type into.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !HardwareKeys.send($0, down: true, to: self) }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !HardwareKeys.send($0, down: false, to: self) }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !HardwareKeys.send($0, down: false, to: self) }
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    override var canBecomeFirstResponder: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // A rotated screen is a different frame for the picture; start it unmagnified.
        coordinator.animate(alongsideTransition: { _ in
            self.scale = 1
            self.panX = 0
            self.panY = 0
            self.applyTransform()
        })
    }

    // MARK: Session

    private func start() {
        let name = target.peer.name
        showStatus("looking for \(name)")
        let stream = client.events
        events = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
        connecting = Task { [weak self] in
            guard let self else { return }
            await client.attach(renderer: videoView)
            // Every address is probed at once. A Mac usually has a home address and a tailnet one,
            // and trying them in turn means waiting out a timeout on the wrong network first.
            let urls = target.addresses.compactMap(Endpoints.url(for:))
            guard let url = await Endpoints.firstReachable(urls) else {
                finish("no address")
                return
            }
            guard !Task.isCancelled else { return }
            address = AppModel.address(of: url)
            showStatus("\(address ?? url.absoluteString) answered")
            await client.connect(url: url)
        }
    }

    private func handle(_ event: SessionClient.Event) {
        switch event {
        case .state(let state):
            switch state {
            case .idle: break
            case .connecting: showStatus("connecting to \(target.peer.name)")
            case .authenticating: showStatus("checking it is \(target.peer.name)")
            case .negotiating: showStatus("asking for the screen")
            case .connected(let path):
                route = path
                if let address { model?.sessionConnected(target, address: address) }
                let size = display.map { "\($0.width_px)x\($0.height_px)  ·  " } ?? ""
                showStatus("\(size)\(path)", hideAfter: 2.5)
            case .reconnecting(let why):
                showStatus("reconnecting: \(why)")
            case .ended(let reason):
                finish(reason)
            }
        case .display(let info):
            // A restarted capture can be a different size, and every touch is mapped through this.
            display = info
        case .capture(let state, let detail):
            showCapture(state, detail: detail)
        case .rtt(let ms):
            roundTripMs = ms
        case .remoteVideo:
            model?.note("receiving \(target.peer.name)'s screen")
        case .log(let text):
            model?.note(text)
        }
    }

    private func send(_ message: DataChannelMessage) {
        let client = self.client
        outbound.enqueue { await client.send(message) }
    }

    private func finish(_ reason: String) {
        guard !finished else { return }
        finished = true
        infoTimer?.invalidate()
        connecting?.cancel()
        events?.cancel()
        _ = keyboard.resignFirstResponder()
        model?.sessionEnded(target, reason: reason)
    }

    // MARK: Layout

    private func buildLayout() {
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoView.videoContentMode = .scaleAspectFit
        videoView.delegate = self
        videoView.isUserInteractionEnabled = false
        videoView.backgroundColor = .black
        view.addSubview(videoView)

        // The touch surface sits over the whole screen and never moves. Pinching scales the video,
        // and a surface that moved with it would report fingers in a shifting frame.
        surface.frame = view.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.isMultipleTouchEnabled = true
        surface.owner = self
        surface.accessibilityIdentifier = "session-surface"
        surface.isAccessibilityElement = true
        surface.accessibilityLabel = "The Mac's screen"
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        // The raw touches must keep arriving during a pinch: they are what the gestures read.
        pinch.cancelsTouchesInView = false
        pinch.delaysTouchesBegan = false
        pinch.delaysTouchesEnded = false
        surface.addGestureRecognizer(pinch)
        view.addSubview(surface)

        // Shown under the finger while a drag holds the mouse button down. Without something to
        // see, "tap twice and hold" is invisible: the Mac thinks a button is pressed and nothing
        // here says so.
        holdMark.frame = CGRect(x: 0, y: 0, width: 56, height: 56)
        holdMark.layer.cornerRadius = 28
        holdMark.backgroundColor = UIColor(hex: 0x4D8EF7, alpha: 0.33)
        holdMark.layer.borderColor = UIColor(Theme.accent).cgColor
        holdMark.layer.borderWidth = 2
        holdMark.isUserInteractionEnabled = false
        holdMark.isHidden = true
        holdMark.accessibilityIdentifier = "hold-mark"
        view.addSubview(holdMark)

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = UIColor(Theme.text)
        statusLabel.backgroundColor = UIColor(white: 0, alpha: 0.67)
        statusLabel.numberOfLines = 2
        statusLabel.accessibilityIdentifier = "session-status"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // A banner rather than a curtain: while the Mac's capture is paused the last frame stays on
        // screen and input still reaches it, so the picture stays visible and touchable underneath.
        captureBanner.font = .systemFont(ofSize: Theme.uiSecondary)
        captureBanner.textColor = UIColor(Theme.text)
        captureBanner.backgroundColor = UIColor(hex: 0x1B1B1B, alpha: 0.9)
        captureBanner.numberOfLines = 0
        captureBanner.isHidden = true
        captureBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captureBanner)

        // A sidebar rather than labelled buttons: it sits on the black bar beside a wide picture,
        // or below it in portrait, so it costs little of the Mac's screen.
        sidebar.axis = .vertical
        sidebar.spacing = 2
        sidebar.backgroundColor = UIColor(hex: 0x1B1B1B, alpha: 0.9)
        sidebar.layer.cornerRadius = 10
        sidebar.isLayoutMarginsRelativeArrangement = true
        sidebar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        modeButton = iconButton("hand.point.up.left", name: "Touch", id: "session-mode") { [weak self] in self?.toggleMode() }
        keyboardButton = iconButton("keyboard", name: "Keyboard", id: "session-keyboard") { [weak self] in self?.toggleKeyboard() }
        infoButton = iconButton("info.circle", name: "Session info", id: "session-info") { [weak self] in self?.toggleInfo() }
        let endButton = iconButton("xmark.circle", name: "End session", id: "session-end") { [weak self] in self?.confirmEnd() }
        [modeButton, keyboardButton, infoButton, endButton].forEach { sidebar.addArrangedSubview($0) }
        view.addSubview(sidebar)

        infoContainer.backgroundColor = UIColor(hex: 0x1B1B1B, alpha: 0.92)
        infoContainer.layer.cornerRadius = 10
        infoContainer.isHidden = true
        infoContainer.translatesAutoresizingMaskIntoConstraints = false
        infoPanel.axis = .vertical
        infoPanel.spacing = 2
        infoPanel.translatesAutoresizingMaskIntoConstraints = false
        infoContainer.addSubview(infoPanel)
        view.addSubview(infoContainer)

        // Off to the side, so the soft keyboard has something to type into. What it types is sent
        // as text, which is the only way a phone keyboard produces characters faithfully.
        keyboard.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        keyboard.alpha = 0.01
        keyboard.delegate = self
        view.addSubview(keyboard)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -60),

            captureBanner.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            captureBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureBanner.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, multiplier: 0.8),

            infoContainer.widthAnchor.constraint(equalToConstant: 230),
            infoPanel.topAnchor.constraint(equalTo: infoContainer.topAnchor, constant: 12),
            infoPanel.bottomAnchor.constraint(equalTo: infoContainer.bottomAnchor, constant: -12),
            infoPanel.leadingAnchor.constraint(equalTo: infoContainer.leadingAnchor, constant: 14),
            infoPanel.trailingAnchor.constraint(equalTo: infoContainer.trailingAnchor, constant: -14),
        ])

        // The info panel is anchored apart from the icons, so opening it does not move the icon
        // under the thumb that just pressed it.
        besideConstraints = [
            sidebar.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -4),
            sidebar.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            infoContainer.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: -8),
            infoContainer.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
        ]
        belowConstraints = [
            sidebar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // Above the keyboard when it is open, so the icon that closes it is never under it.
            sidebar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
            infoContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            infoContainer.bottomAnchor.constraint(equalTo: sidebar.topAnchor, constant: -8),
        ]

        let saved = UserDefaults.standard.string(forKey: "inputMode").flatMap(Gestures.Mode.init(rawValue:))
        setMode(saved ?? .touch, announce: false)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        placeSidebar()
    }

    private func placeSidebar() {
        let row = view.bounds.height > view.bounds.width || keyboard.isFirstResponder
        guard row != inRow else { return }
        inRow = row
        NSLayoutConstraint.deactivate(row ? besideConstraints : belowConstraints)
        sidebar.axis = row ? .horizontal : .vertical
        sidebar.directionalLayoutMargins = row
            ? NSDirectionalEdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10)
            : NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)
        NSLayoutConstraint.activate(row ? belowConstraints : besideConstraints)
    }

    private func iconButton(_ symbol: String, name: String, id: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        config.baseForegroundColor = UIColor(Theme.textDim)
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = name
        button.accessibilityIdentifier = id
        button.widthAnchor.constraint(equalToConstant: 46).isActive = true
        button.heightAnchor.constraint(equalToConstant: 46).isActive = true
        // Held down, an icon says what it is: the icons carry no labels, like the Android sidebar's.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(iconHeld(_:)))
        button.addGestureRecognizer(hold)
        return button
    }

    @objc private func iconHeld(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let name = recognizer.view?.accessibilityLabel else { return }
        showStatus(name, hideAfter: 1.5)
    }

    private func tint(_ button: UIButton, on: Bool) {
        button.configuration?.baseForegroundColor = on ? UIColor(Theme.accent) : UIColor(Theme.textDim)
    }

    // MARK: Status and banners

    private func showStatus(_ text: String, hideAfter seconds: Double? = nil) {
        statusLabel.text = text
        statusLabel.isHidden = false
        hideStatusWork?.cancel()
        hideStatusWork = nil
        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.statusLabel.isHidden = true }
            hideStatusWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    private func showCapture(_ state: CaptureState, detail: String?) {
        let text: String?
        switch state {
        case .active: text = nil
        case .pausedLocked: text = "The Mac is locked. Its screen is frozen until it is unlocked."
        case .pausedDisplayAsleep: text = "The Mac's display is asleep. Its screen is frozen."
        case .pausedError: text = "The Mac stopped capturing its screen\(detail.map { " (\($0))" } ?? ""). Retrying."
        }
        // The Mac sends its state when the channel opens too, when nothing had paused.
        let wasPaused = !captureBanner.isHidden
        captureBanner.text = text
        captureBanner.isHidden = text == nil
        model?.note(text ?? (wasPaused ? "screen capture resumed" : "screen capture active"))
    }

    // MARK: Sidebar actions

    private func toggleMode() {
        setMode(gestures.mode == .touch ? .trackpad : .touch, announce: true)
    }

    private func setMode(_ mode: Gestures.Mode, announce: Bool) {
        gestures.mode = mode
        let touch = mode == .touch
        modeButton.configuration?.image = UIImage(systemName: touch ? "hand.point.up.left" : "rectangle.and.hand.point.up.left",
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 18))
        modeButton.accessibilityLabel = touch ? "Touch" : "Trackpad"
        modeButton.accessibilityValue = touch ? "touch" : "trackpad"
        tint(modeButton, on: !touch)
        UserDefaults.standard.set(mode.rawValue, forKey: "inputMode")
        if announce {
            showStatus(touch ? "Touch: the pointer goes where you tap" : "Trackpad: drag to move the pointer, tap to click", hideAfter: 2.2)
        }
    }

    private func toggleKeyboard() {
        if keyboard.isFirstResponder {
            _ = keyboard.resignFirstResponder()
            becomeFirstResponder()
        } else {
            keyboard.becomeFirstResponder()
        }
        tint(keyboardButton, on: keyboard.isFirstResponder)
        placeSidebar()
    }

    /// Ending drops the session, so a tap next to the info button should not do it silently.
    private func confirmEnd() {
        let alert = UIAlertController(title: "End the session?",
                                      message: "The screen closes and \(target.peer.name) goes back to being on its own.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Stay", style: .cancel))
        alert.addAction(UIAlertAction(title: "End", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let client = self.client
            Task { await client.disconnect() }
        })
        present(alert, animated: true)
    }

    /// Everything worth knowing about the session: which Mac, over which address and route, and
    /// what the stream is actually doing, read from the peer connection rather than guessed.
    private func toggleInfo() {
        let showing = !infoContainer.isHidden
        infoContainer.isHidden = showing
        tint(infoButton, on: !showing)
        infoTimer?.invalidate()
        infoTimer = nil
        guard !showing else { return }
        refreshInfo(nil)
        infoTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sampleInfo() }
        }
        Task { await sampleInfo() }
    }

    private func sampleInfo() async {
        let stats = await client.videoStats()
        guard !infoContainer.isHidden else { return }
        refreshInfo(stats)
    }

    private func refreshInfo(_ stats: WebRTCClient.InboundVideoStats?) {
        infoPanel.arrangedSubviews.forEach { $0.removeFromSuperview() }
        heading("SESSION")
        row("Mac", target.peer.name)
        row("Address", address ?? "finding it")
        row("Route", route ?? "not yet")
        if let display { row("Its screen", "\(display.width_px) x \(display.height_px)") }
        heading("STREAM")
        if let stats, stats.width > 0 {
            row("Now", "\(stats.width) x \(stats.height)")
            row("Frames", String(format: "%.0f a second", stats.fps))
            row("Bitrate", String(format: "%.0f kbps", stats.kbps))
            row("Codec", stats.codec ?? "unknown", id: "info-codec")
            row("Lost", "\(stats.packetsLost) packets")
            row("Jitter", String(format: "%.0f ms", stats.jitterMs))
        } else {
            row("Now", "waiting")
        }
        if let roundTripMs { row("Round trip", String(format: "%.0f ms", roundTripMs)) }
        heading("THIS \(AppModel.deviceKind.uppercased())")
        row("Input", gestures.mode == .touch ? "Touch" : "Trackpad")
        row("Zoom", scale <= 1 ? "fit" : String(format: "%.1fx", scale))
    }

    private func heading(_ title: String) {
        let label = UILabel()
        label.attributedText = NSAttributedString(string: title, attributes: [
            .font: UIFont.systemFont(ofSize: 9, weight: .bold), .kern: 1, .foregroundColor: UIColor(Theme.textFaint),
        ])
        let spacer = UIView()
        spacer.heightAnchor.constraint(equalToConstant: infoPanel.arrangedSubviews.isEmpty ? 0 : 6).isActive = true
        infoPanel.addArrangedSubview(spacer)
        infoPanel.addArrangedSubview(label)
    }

    /// The value takes the rest of the row and sits against the right edge, so the two columns read
    /// as a table rather than as a label with a hole beside it.
    private func row(_ name: String, _ value: String, id: String? = nil) {
        let left = UILabel()
        left.text = name
        left.font = .systemFont(ofSize: 10)
        left.textColor = UIColor(Theme.textFaint)
        left.setContentHuggingPriority(.required, for: .horizontal)
        let right = UILabel()
        right.text = value
        right.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        right.textColor = UIColor(Theme.text)
        right.textAlignment = .right
        right.lineBreakMode = .byTruncatingMiddle
        right.accessibilityIdentifier = id
        let line = UIStackView(arrangedSubviews: [left, right])
        line.spacing = 8
        infoPanel.addArrangedSubview(line)
    }

    // MARK: Magnification

    /// Pinching magnifies the picture here rather than asking the Mac to change anything. A desktop
    /// shrunk onto a phone has text a few pixels tall, and this is the difference between seeing a
    /// menu and guessing at it. The point under the fingers stays under the fingers.
    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            gestures.pinching = true
        case .changed:
            gestures.pinching = true
            let previous = scale
            var next = min(max(scale * recognizer.scale, 1), Self.maxZoom)
            recognizer.scale = 1
            guard next != previous else { return }
            let focus = recognizer.location(in: view)
            let centre = videoView.center
            panX = PointerMapping.panAfterZoom(focus: focus.x, centre: centre.x, pan: panX, from: previous, to: next)
            panY = PointerMapping.panAfterZoom(focus: focus.y, centre: centre.y, pan: panY, from: previous, to: next)
            if next < 1.02 {
                next = 1
                panX = 0
                panY = 0
            }
            scale = next
            clampPan()
            applyTransform()
            showStatus(scale <= 1 ? "1x" : String(format: "%.1fx", scale), hideAfter: 0.9)
        default:
            // Left set until the next touch begins: the fingers lifting are still part of the pinch,
            // and a pinch whose midpoint stayed put must not read as a two-finger tap.
            break
        }
    }

    private func applyTransform() {
        videoView.transform = CGAffineTransform(translationX: panX, y: panY).scaledBy(x: scale, y: scale)
        gestures.magnified = scale > 1.01
    }

    /// Keeps the magnified picture covering the frame, so no black creeps in at an edge.
    private func clampPan() {
        panX = PointerMapping.clampPan(panX, viewSize: videoView.bounds.width, scale: scale)
        panY = PointerMapping.clampPan(panY, viewSize: videoView.bounds.height, scale: scale)
    }

    // MARK: Pointer arithmetic

    private var frameAspect: Double {
        if frameSize.width > 0, frameSize.height > 0 { return frameSize.width / frameSize.height }
        if let display { return Double(display.width_px) / Double(display.height_px) }
        return 16.0 / 9.0
    }

    /// Where the finger is, as a fraction of the Mac's screen. The picture is letterboxed to keep its
    /// aspect ratio, so the black bars come out of the sum before it means anything.
    private func sendMove(_ point: CGPoint) {
        guard let display else { return }
        let now = nowMs()
        if now - lastMoveSent < Int64(Limits.mouseMoveCoalesceMs) { return }
        lastMoveSent = now
        let bounds = videoView.bounds
        let n = PointerMapping.normalized(
            x: point.x, y: point.y,
            viewLeft: videoView.center.x - bounds.width / 2, viewTop: videoView.center.y - bounds.height / 2,
            viewWidth: bounds.width, viewHeight: bounds.height,
            scale: scale, panX: panX, panY: panY, frameAspect: frameAspect)
        send(.mouseMove(displayId: display.display_id, x: n.x, y: n.y))
    }

    /// View points are not the Mac's pixels: the picture is scaled onto the phone and may be
    /// magnified on top of that.
    private func remotePixelsPerPoint() -> Double {
        let bounds = videoView.bounds
        let content = PointerMapping.contentSize(viewWidth: bounds.width, viewHeight: bounds.height, frameAspect: frameAspect)
        guard content.width > 0 else { return 1 }
        let remoteWidth = frameSize.width > 0 ? frameSize.width : Double(display?.width_px ?? Int(content.width))
        return remoteWidth / (content.width * scale)
    }

    private static func clamp(_ value: Double, _ limit: Double) -> Double { min(max(value, -limit), limit) }
}

// MARK: - Touches

extension SessionViewController {
    fileprivate func surfaceDown(_ point: CGPoint, time: Int64) {
        // A new gesture: whatever pinch came before it is over.
        gestures.pinching = false
        gestures.magnified = scale > 1.01
        gestures.down(x: point.x, y: point.y, time: time)
    }

    fileprivate func surfacePointerDown(count: Int, focus: CGPoint, time: Int64) {
        gestures.pointerDown(count: count, focusX: focus.x, focusY: focus.y, time: time)
    }

    fileprivate func surfaceMove(count: Int, point: CGPoint, focus: CGPoint) {
        gestures.move(count: count, x: point.x, y: point.y, focusX: focus.x, focusY: focus.y)
    }

    fileprivate func surfaceUp(_ point: CGPoint, time: Int64) {
        gestures.up(x: point.x, y: point.y, time: time)
    }

    fileprivate func surfaceCancelled() {
        gestures.cancel()
    }
}

extension SessionViewController: GestureOutput {
    func moveTo(x: Double, y: Double) {
        sendMove(CGPoint(x: x, y: y))
    }

    func moveBy(dx: Double, dy: Double) {
        let factor = remotePixelsPerPoint() * Self.trackpadSpeed
        send(.mouseMoveRel(dx: Self.clamp(dx * factor, Limits.maxRelativeDelta), dy: Self.clamp(dy * factor, Limits.maxRelativeDelta)))
    }

    func click(_ button: MouseButton) {
        send(.mouseDown(button))
        send(.mouseUp(button))
    }

    func buttonDown(_ button: MouseButton) { send(.mouseDown(button)) }

    func buttonUp(_ button: MouseButton) { send(.mouseUp(button)) }

    func scroll(dx: Double, dy: Double) {
        // In pixels, as the Android app sends them: a point here is about three of its pixels, so
        // the same finger travel scrolls the Mac the same distance from either phone.
        let pixels = Double(traitCollection.displayScale)
        send(.scroll(dx: Self.clamp(dx * pixels, Limits.maxScrollDelta), dy: Self.clamp(dy * pixels, Limits.maxScrollDelta), precise: true, phase: nil))
    }

    func pan(dx: Double, dy: Double) {
        panX += dx
        panY += dy
        clampPan()
        applyTransform()
    }

    func holding(x: Double, y: Double, held: Bool) {
        holdMark.isHidden = !held
        if held { holdMark.center = CGPoint(x: x, y: y) }
    }
}

extension SessionViewController: RTCVideoViewDelegate {
    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        DispatchQueue.main.async { [weak self] in
            guard let self, size != self.frameSize else { return }
            self.frameSize = size
            self.model?.note("frame \(Int(size.width)) x \(Int(size.height))")
        }
    }
}

// MARK: - Keyboard

extension SessionViewController: KeyboardCatcherDelegate {
    func keyboardTyped(_ text: String) {
        for chunk in KeyCodes.textChunks(text) { send(.text(chunk)) }
    }

    func keyboardKey(_ code: String, modifiers: [Modifier], down: Bool) {
        send(down ? .keyDown(code: code, modifiers: modifiers, repeat: false) : .keyUp(code: code, modifiers: modifiers))
    }

    func keyboardClosed() {
        tint(keyboardButton, on: false)
        placeSidebar()
        becomeFirstResponder()
    }
}

// MARK: - Pieces

/// The full-screen view that reads fingers. It tracks them in the order they landed, so the first
/// finger stays the one that points and a second one only adds to the gesture.
final class TouchSurface: UIView {
    fileprivate weak var owner: SessionViewController?
    private var active: [UITouch] = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasEmpty = active.isEmpty
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) where !active.contains(touch) {
            active.append(touch)
        }
        guard let first = active.first else { return }
        let time = Self.ms(touches.first?.timestamp ?? first.timestamp)
        if wasEmpty { owner?.surfaceDown(first.location(in: self), time: time) }
        // Two fingers landing together arrive in one call: that is the start of a two-finger tap.
        if active.count > 1 { owner?.surfacePointerDown(count: active.count, focus: focus(), time: time) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let first = active.first else { return }
        owner?.surfaceMove(count: active.count, point: first.location(in: self), focus: focus())
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let point = active.first?.location(in: self) ?? .zero
        let time = Self.ms(touches.first?.timestamp ?? 0)
        active.removeAll { touches.contains($0) }
        if active.isEmpty { owner?.surfaceUp(point, time: time) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.removeAll { touches.contains($0) }
        if active.isEmpty { owner?.surfaceCancelled() }
    }

    /// Between the first two fingers: what a two-finger scroll or pan follows.
    private func focus() -> CGPoint {
        guard active.count >= 2 else { return active.first?.location(in: self) ?? .zero }
        let a = active[0].location(in: self), b = active[1].location(in: self)
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private static func ms(_ seconds: TimeInterval) -> Int64 { Int64(seconds * 1000) }
}

/// The gestures' timers, on the main queue.
final class MainQueueScheduler: GestureScheduler {
    private var next = 0
    private var work: [Int: DispatchWorkItem] = [:]

    func after(_ delayMs: Int64, _ action: @escaping () -> Void) -> Int {
        next += 1
        let token = next
        let item = DispatchWorkItem { [weak self] in
            self?.work[token] = nil
            action()
        }
        work[token] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: item)
        return token
    }

    func cancel(_ token: Int) {
        work.removeValue(forKey: token)?.cancel()
    }
}

/// A label with room around its text, for status and banners over the picture.
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let inner = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
        return inner.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = 6
        layer.masksToBounds = true
    }
}
