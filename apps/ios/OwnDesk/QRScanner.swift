import AVFoundation
import SwiftUI
import UIKit

/// Reads the pairing QR a Mac shows, with the system's own QR detector. Nothing leaves the device.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onCancel: () -> Void

    /// False in the Simulator and on anything else without a camera.
    static var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        controller.onCancel = onCancel
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "owndesk.scanner")
    private var preview: AVCaptureVideoPreviewLayer?
    private let hint = UILabel()
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let frame = UIView()
        frame.layer.borderColor = UIColor(Theme.accent).cgColor
        frame.layer.borderWidth = 3
        frame.layer.cornerRadius = 14
        frame.isUserInteractionEnabled = false
        frame.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frame)

        hint.text = "Point the camera at the code on the Mac's screen"
        hint.textColor = UIColor(Theme.text)
        hint.font = .systemFont(ofSize: 15, weight: .medium)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        var config = UIButton.Configuration.filled()
        config.title = "Cancel"
        config.baseBackgroundColor = UIColor(white: 0.15, alpha: 0.9)
        config.baseForegroundColor = UIColor(Theme.text)
        config.cornerStyle = .capsule
        let cancel = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.finish(nil) })
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)

        NSLayoutConstraint.activate([
            frame.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frame.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            frame.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.72),
            frame.heightAnchor.constraint(equalTo: frame.widthAnchor),
            hint.topAnchor.constraint(equalTo: frame.bottomAnchor, constant: 24),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { granted ? self?.configure() : self?.denied() }
            }
        default:
            denied()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        sessionQueue.async { session.stopRunning() }
    }

    private func configure() {
        // A virtual camera switches to the ultra-wide lens for close focus on the models that need
        // it, which is what a phone held near a screen needs.
        let device = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            hint.text = "The camera could not be opened. Paste the code instead."
            return
        }
        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            hint.text = "The camera cannot read codes here. Paste the code instead."
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        // A camera aimed at a screen tends to settle on the room behind it; favour near subjects.
        if (try? device.lockForConfiguration()) != nil {
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        preview = layer

        let session = self.session
        sessionQueue.async { session.startRunning() }
    }

    private func denied() {
        hint.text = "Camera access is off for OwnDesk. Allow it in Settings, or paste the code instead."
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered,
              let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first(where: { $0.type == .qr }),
              let text = code.stringValue, !text.isEmpty
        else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        finish(text)
    }

    private func finish(_ text: String?) {
        guard !delivered else { return }
        delivered = true
        let session = self.session
        sessionQueue.async { session.stopRunning() }
        if let text { onCode?(text) } else { onCancel?() }
    }
}
