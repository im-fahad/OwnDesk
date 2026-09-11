import PRCControllerCore
import PRCPeers
import PRCProtocol
import SwiftUI

/// Editor-style layout: a fixed header, panels that come and go, and the remote screen filling
/// whatever is left. Only the screen is permanent; the sidebar and the log are toggles.
struct ContentView: View {
    @EnvironmentObject var model: AppState
    @State private var showPairing = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(showPairing: $showPairing)
            HRule()
            HStack(spacing: 0) {
                if model.showSidebar {
                    SidebarPanel(showPairing: $showPairing)
                        .frame(width: 232)
                        .background(Theme.sidebar)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    VRule()
                }
                VStack(spacing: 0) {
                    ScreenArea()
                    if model.showLog {
                        HRule()
                        LogPanel()
                            .frame(height: 168)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            HRule()
            StatusBar()
        }
        // Without this SwiftUI keeps a safe area where the title bar used to be, and the header
        // renders as a second row below the traffic lights instead of beside them.
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.content)
        .background(WindowChrome())
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.15), value: model.showSidebar)
        .animation(.easeOut(duration: 0.15), value: model.showLog)
        .sheet(isPresented: $showPairing) { PairingSheet(isPresented: $showPairing) }
    }

}

/// One-pixel separators. A Divider inside a coloured chrome picks up the wrong tint.
struct HRule: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: 1) }
}

struct VRule: View {
    var body: some View { Rectangle().fill(Theme.border).frame(width: 1) }
}

// MARK: - Header

struct HeaderBar: View {
    @EnvironmentObject var model: AppState
    @Binding var showPairing: Bool

    var body: some View {
        ZStack {
            // Centred title, as an editor puts its document name, laid over the controls so it stays
            // centred in the window rather than in the gap between them.
            title
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 260)

            HStack(spacing: 6) {
                // Room for the traffic lights, which share this row.
                Spacer().frame(width: Theme.trafficLightInset)

                IconButton(systemName: "sidebar.leading", help: "Toggle hosts (⌘B)", isOn: model.showSidebar) {
                    model.showSidebar.toggle()
                }
                IconButton(systemName: "text.alignleft", help: "Toggle log (⌘J)", isOn: model.showLog) {
                    model.showLog.toggle()
                }

                Spacer(minLength: 12)

                if model.isConnected {
                    connectedControls
                } else {
                    idleControls
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: Theme.headerHeight)
        .frame(maxWidth: .infinity)
        .background(TitleBarBackground())
    }

    private var title: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if let id = model.selectedPeerId, let host = model.peers.peer(id) {
                Circle()
                    .fill(model.isConnected ? Theme.online : (model.isBusy ? Theme.warn : Theme.textFaint))
                    .frame(width: 7, height: 7)
                Text(host.name).font(Theme.uiMedium).foregroundStyle(Theme.text)
                Text(host.fingerprint).font(Theme.monoSmall).foregroundStyle(Theme.textFaint)
            } else {
                Text("No host selected").font(Theme.ui).foregroundStyle(Theme.textDim)
            }
            Text(model.stateSummary).font(Theme.uiSecondary).foregroundStyle(Theme.textDim)
            if let incoming = model.incoming {
                Text("· \(incoming.deviceName) is controlling this Mac")
                    .font(Theme.uiSecondary).foregroundStyle(Theme.warn)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .allowsHitTesting(false)
    }

    private var connectedControls: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Resolution", selection: $model.quality) {
                    ForEach(QualityPreset.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Trade-off", selection: $model.smoothMotion) {
                    Text("Sharp text").tag(false)
                    Text("Smooth motion").tag(true)
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.quality == .auto ? "Quality" : model.quality.label, systemImage: "slider.horizontal.3")
                    .font(Theme.uiSecondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(Theme.textDim)

            Menu {
                Button("⌘ Tab") { model.sendShortcut("Tab", modifiers: [.meta]) }
                Button("⌘ Space") { model.sendShortcut("Space", modifiers: [.meta]) }
                Button("⌘ Q") { model.sendShortcut("KeyQ", modifiers: [.meta]) }
                Divider()
                Button("Send text…") { model.showTextField.toggle() }
            } label: {
                Label("Keys", systemImage: "command").font(Theme.uiSecondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(Theme.textDim)

            IconButton(systemName: model.sendInput ? "cursorarrow.click" : "cursorarrow.slash",
                       help: model.sendInput ? "Input is being sent" : "Input is paused",
                       isOn: model.sendInput) { model.sendInput.toggle() }

            Button("Disconnect") { model.disconnect() }
                .buttonStyle(HeaderButtonStyle(tint: Theme.danger))
        }
    }

    private var idleControls: some View {
        HStack(spacing: 6) {
            TextField("address override", text: $model.manualAddress)
                .textFieldStyle(.plain)
                .font(Theme.uiSecondary)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.content, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border))
                .frame(width: 190)

            Button(model.isBusy ? "Connecting…" : "Connect") { model.connect() }
                .buttonStyle(HeaderButtonStyle(tint: Theme.accent))
                .disabled(model.selectedPeerId == nil || model.isBusy)
        }
    }
}

struct HeaderButtonStyle: ButtonStyle {
    var tint: Color
    /// The sidebar's buttons sit among smaller text and should not tower over it.
    var compact = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? 8 : 10).padding(.vertical, compact ? 2 : 3)
            .background(hovering || configuration.isPressed ? tint.opacity(0.16) : tint.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(tint.opacity(0.35)))
            .onHover { hovering = $0 }
    }
}

// MARK: - Sidebar

struct SidebarPanel: View {
    @EnvironmentObject var model: AppState
    @Binding var showPairing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Macs you can control")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.hostablePeers) { peer in
                        HostRow(host: peer, isSelected: model.selectedPeerId == peer.deviceId)
                            .onTapGesture { model.selectedPeerId = peer.deviceId }
                            .contextMenu { peerMenu(peer) }
                    }
                    if model.hostablePeers.isEmpty {
                        Text("None yet.")
                            .font(Theme.sidebarSecondary).foregroundStyle(Theme.textFaint)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }

                    let inbound = model.peerList.filter { $0.mayControlUs && !$0.weMayControl }
                    if !inbound.isEmpty {
                        sectionHeader("Macs that can control this one").padding(.top, 8)
                        ForEach(inbound) { peer in
                            HostRow(host: peer, isSelected: false)
                                .contextMenu { peerMenu(peer) }
                        }
                    }

                    let unpaired = model.discovered.filter { d in !model.peerList.contains { $0.deviceId == d.deviceId } }
                    if !unpaired.isEmpty {
                        sectionHeader("Nearby, not paired").padding(.top, 8)
                        ForEach(unpaired) { d in
                            Text(d.name)
                                .font(Theme.sidebarSecondary).foregroundStyle(Theme.textFaint)
                                .padding(.horizontal, 12).padding(.vertical, 3)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Spacer(minLength: 0)
            HRule()
            thisMac
        }
    }

    @ViewBuilder private func peerMenu(_ peer: Peer) -> some View {
        if peer.weMayControl {
            Button("Connect") { model.selectedPeerId = peer.deviceId; model.connect() }
            Divider()
        }
        Toggle("This Mac may control it", isOn: Binding(
            get: { peer.weMayControl },
            set: { model.setWeMayControl(peer.deviceId, $0) }))
        Toggle("It may control this Mac", isOn: Binding(
            get: { peer.mayControlUs },
            set: { model.setMayControlUs(peer.deviceId, $0) }))
        Divider()
        Button("Forget \(peer.fingerprint)", role: .destructive) { model.forget(peer.deviceId) }
    }

    private var thisMac: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("THIS MAC").font(Theme.sidebarSection).foregroundStyle(Theme.textFaint).tracking(0.5)
            Text(model.fingerprint).font(Theme.sidebarMonoLarge).foregroundStyle(Theme.text)
            Toggle(isOn: Binding(get: { model.hosting }, set: { model.setHosting($0) })) {
                Text("Let others control it").font(Theme.sidebarSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            if let s = model.incoming {
                HStack(spacing: 5) {
                    Circle().fill(s.path == nil ? Theme.warn : Theme.online).frame(width: 6, height: 6)
                    Text("\(s.deviceName): \(s.path ?? s.phase)").font(Theme.sidebarSecondary).foregroundStyle(Theme.textDim).lineLimit(1)
                    Spacer(minLength: 0)
                    Button("End") { model.endIncoming() }.buttonStyle(HeaderButtonStyle(tint: Theme.danger, compact: true))
                }
            }
            Button("Pair a Mac…") { showPairing = true }
                .buttonStyle(HeaderButtonStyle(tint: Theme.accent, compact: true))
        }
        .padding(12)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.sidebarSection).tracking(0.5)
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
    }
}

struct HostRow: View {
    @EnvironmentObject var model: AppState
    let host: Peer
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.discoveredPeer(for: host.deviceId) != nil ? Theme.online : Theme.textFaint)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name).font(Theme.sidebarItem).foregroundStyle(Theme.text).lineLimit(1)
                // The fingerprint is what tells two entries for the same Mac apart, so it has to be
                // readable rather than decorative.
                Text(host.fingerprint).font(Theme.sidebarMono).foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(isSelected ? Theme.selection : (hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Screen

struct ScreenArea: View {
    @EnvironmentObject var model: AppState
    /// Bumped when the Dock icon comes or goes. Changing the app's activation policy leaves an
    /// existing Metal-backed video view drawing nothing, so it is replaced rather than reused.
    @State private var videoGeneration = 0

    var body: some View {
        ZStack {
            Color.black
            // Kept in the hierarchy at all times so the renderer is attached once and the stream
            // survives every panel toggle.
            VideoView()
                .id(videoGeneration)
            if !model.isConnected { placeholder }
            if model.isConnected, !model.captureState.isActive { captureBanner }
            if model.showTextField { textOverlay }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .prcRebuildVideo)) { _ in
            videoGeneration += 1
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "display").font(.system(size: 34)).foregroundStyle(Theme.textFaint)
            Text(model.placeholderTitle).font(Theme.ui).foregroundStyle(Theme.textDim)
            if let detail = model.placeholderDetail {
                Text(detail).font(Theme.uiSecondary).foregroundStyle(Theme.textFaint)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            if !model.isBusy, model.selectedPeerId != nil {
                Button("Connect") { model.connect() }
                    .buttonStyle(HeaderButtonStyle(tint: Theme.accent))
                    .padding(.top, 2)
            }
        }
        .padding(28)
        .background(Theme.content.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
    }

    /// A banner rather than a curtain: the picture is stale but input still reaches the other Mac,
    /// so the frozen desktop stays visible and clickable underneath.
    private var captureBanner: some View {
        VStack {
            HStack(spacing: 7) {
                Image(systemName: model.captureState == .pausedLocked ? "lock.fill" : "zzz")
                    .font(.system(size: 11, weight: .semibold))
                Text(AppState.describeCapture(model.captureState))
                    .font(Theme.uiSecondary)
            }
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.content.opacity(0.92), in: Capsule())
            .padding(.top, 10)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var textOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                TextField("Text to type on the host", text: $model.textToSend)
                    .textFieldStyle(.plain)
                    .font(Theme.ui)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                    .onSubmit { model.sendText() }
                Button("Send") { model.sendText() }
                    .buttonStyle(HeaderButtonStyle(tint: Theme.accent))
                IconButton(systemName: "xmark", help: "Close") { model.showTextField = false }
            }
            .padding(10)
            .background(Theme.header.opacity(0.96), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            .padding(14)
        }
    }
}

// MARK: - Log

struct LogPanel: View {
    @EnvironmentObject var model: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("LOG").font(Theme.section).tracking(0.5).foregroundStyle(Theme.text)
                Spacer()
                IconButton(systemName: "trash", help: "Clear") { model.log.removeAll() }
                IconButton(systemName: "xmark", help: "Hide (⌘J)") { model.showLog = false }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(Theme.mono)
                            .foregroundStyle(Theme.textDim).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .background(Theme.panel)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject var model: AppState

    var body: some View {
        HStack(spacing: 12) {
            item(model.isConnected ? "bolt.horizontal.fill" : "bolt.horizontal", model.stateSummary)
            if let d = model.display {
                item("display", "\(d.width_px)×\(d.height_px)")
            }
            if model.videoSize != .zero {
                item("arrow.down.circle", "\(Int(model.videoSize.width))×\(Int(model.videoSize.height))")
            }
            if let rtt = model.rtt {
                item("timer", "\(Int(rtt)) ms")
            }
            Spacer()
            if model.isConnected {
                Text(model.quality == .auto ? "Automatic quality" : model.quality.label)
                    .font(Theme.uiSmall).foregroundStyle(Theme.textFaint)
            }
            Text(model.fingerprint).font(Theme.monoSmall).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Theme.status)
    }

    private func item(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(Theme.uiSmall)
        }
        .foregroundStyle(Theme.textDim)
    }
}

// MARK: - Pairing

struct PairingSheet: View {
    @EnvironmentObject var model: AppState
    @Binding var isPresented: Bool
    @State private var mode = Mode.enter

    enum Mode: String, CaseIterable, Identifiable {
        case enter, show
        var id: String { rawValue }
        var label: String { self == .enter ? "Use a code" : "Show a code" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair a Mac").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .enter { enterCode } else { showCode }

            if !model.pairingStatus.isEmpty {
                Text(model.pairingStatus).font(Theme.uiSecondary).foregroundStyle(Theme.warn)
            }
            HStack {
                Spacer()
                Button("Close") { isPresented = false }.buttonStyle(HeaderButtonStyle(tint: Theme.textDim))
                if mode == .enter {
                    Button(model.isPairing ? "Waiting for approval…" : "Pair") { model.usePairingCode() }
                        .buttonStyle(HeaderButtonStyle(tint: Theme.accent))
                        .disabled(model.isPairing || model.pairingText.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Theme.header)
        .preferredColorScheme(.dark)
    }

    private var enterCode: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On the other Mac, choose Show a code, then paste it here. Approve there only if it displays this Mac's fingerprint:")
                .font(Theme.uiSecondary).foregroundStyle(Theme.textDim)
            Text(model.fingerprint).font(.system(size: 22, design: .monospaced)).foregroundStyle(Theme.text)
            TextEditor(text: $model.pairingText)
                .font(Theme.monoSmall)
                .scrollContentBackground(.hidden)
                .background(Theme.content)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            TextField("Address override (optional)", text: $model.pairingAddress)
                .textFieldStyle(.plain)
                .font(Theme.uiSecondary)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Theme.content, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border))
        }
    }

    @ViewBuilder private var showCode: some View {
        if let request = model.pendingRequest {
            VStack(alignment: .leading, spacing: 12) {
                Label("Pairing request", systemImage: "person.badge.key").font(.headline).foregroundStyle(Theme.text)
                Text("\"\(request.name)\" wants to pair.").foregroundStyle(Theme.text)
                Text("Its fingerprint").font(Theme.uiSecondary).foregroundStyle(Theme.textDim)
                Text(request.fingerprint).font(.system(size: 26, design: .monospaced)).bold().foregroundStyle(Theme.text)
                Text("Approve only if that Mac shows the same fingerprint. If it differs, deny: someone else is trying to pair.")
                    .font(Theme.uiSecondary).foregroundStyle(Theme.textDim)
                HStack {
                    Spacer()
                    Button("Deny") { model.denyPairing() }.buttonStyle(HeaderButtonStyle(tint: Theme.danger))
                    Button("Approve") { model.approvePairing() }.buttonStyle(HeaderButtonStyle(tint: Theme.accent))
                }
            }
        } else if let invite = model.invite {
            HStack(alignment: .top, spacing: 16) {
                if let image = invite.image {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 200, height: 200)
                        .background(Color.white).cornerRadius(6)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan this, or copy the text and paste it on the other Mac.")
                        .font(Theme.uiSecondary).foregroundStyle(Theme.textDim)
                    Text("This Mac's fingerprint").font(Theme.uiSecondary).foregroundStyle(Theme.textDim)
                    Text(model.fingerprint).font(.system(size: 18, design: .monospaced)).foregroundStyle(Theme.text)
                    Button("Copy code") { model.copyInvite() }.buttonStyle(HeaderButtonStyle(tint: Theme.accent))
                    Button("Cancel") { model.cancelPairing() }.buttonStyle(HeaderButtonStyle(tint: Theme.textDim))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.hosting
                     ? "Show a short-lived code the other Mac can use. It expires in two minutes."
                     : "A code is served by the hosting half, so turn on \"Let others control it\" first.")
                    .font(Theme.uiSecondary).foregroundStyle(Theme.textDim)
                Button("Show a code") { model.offerPairing() }
                    .buttonStyle(HeaderButtonStyle(tint: Theme.accent))
                    .disabled(!model.hosting)
            }
        }
    }
}
