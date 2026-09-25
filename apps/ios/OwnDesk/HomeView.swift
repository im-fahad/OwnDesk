import OwnDeskPeers
import SwiftUI

/// The home screen: the Macs this iPhone can control, and what this iPhone is.
///
/// It follows the Mac app's chrome rather than iOS defaults, as the Android app does, because the
/// three are one product: the same dark palette, the same small type, the same section headings, and
/// pairing behind a button instead of a text field left open on screen.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var pairing = false
    @State private var choosingAddress: Peer?
    @State private var unpairing: Peer?
    @State private var showLog = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeading("MACS YOU CAN CONTROL")
                    if let name = model.pairingWith { pairingCard(name) }
                    if model.macs.isEmpty {
                        Text("None yet.")
                            .font(.system(size: Theme.uiSecondary))
                            .foregroundStyle(Theme.textFaint)
                    }
                    ForEach(model.macs) { mac in
                        MacRow(mac: mac)
                            .onTapGesture { model.connect(mac) }
                            .contextMenu {
                                Button("Choose an address…", systemImage: "network") { choosingAddress = mac }
                                if model.pins[mac.deviceId] != nil {
                                    Button("Use any address", systemImage: "arrow.triangle.branch") { model.setPin(nil, for: mac) }
                                }
                                Button("Unpair this Mac…", systemImage: "xmark.circle", role: .destructive) { unpairing = mac }
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .refreshable { model.refresh() }
            .background(Theme.content)
            Divider().overlay(Theme.border)
            thisDevice
            if showLog { logPanel }
            Divider().overlay(Theme.border)
            statusBar
        }
        .background(Theme.content)
        .task { model.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.becameActive()
            case .background: model.wentToBackground()
            default: break
            }
        }
        .sheet(isPresented: $pairing) { PairSheet() }
        .sheet(item: $choosingAddress) { mac in AddressSheet(mac: mac) }
        .confirmationDialog(unpairing.map { "Unpair \($0.name)?" } ?? "", isPresented: Binding(
            get: { unpairing != nil }, set: { if !$0 { unpairing = nil } }), titleVisibility: .visible, presenting: unpairing) { mac in
            Button("Unpair", role: .destructive) { model.unpair(mac) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This \(AppModel.deviceKind) and the Mac forget each other, and must pair again before this \(AppModel.deviceKind) can control it.")
        }
        .alert(model.notice?.title ?? "", isPresented: Binding(
            get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }), presenting: model.notice) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .fullScreenCover(item: $model.activeSession) { target in
            SessionScreen(target: target)
                .environment(model)
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .all)
        }
    }

    private var header: some View {
        Text("OwnDesk")
            .font(.system(size: Theme.title, weight: .bold))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Theme.header.ignoresSafeArea(edges: .top))
    }

    private func pairingCard(_ name: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small).tint(Theme.textDim)
            VStack(alignment: .leading, spacing: 4) {
                Text("Waiting for \(name) to approve")
                    .font(.system(size: Theme.ui))
                    .foregroundStyle(Theme.text)
                Text("Approve on the Mac only when it shows \(model.identity.fingerprint).")
                    .font(.system(size: Theme.uiSmall))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.6)))
    }

    /// What this device is, pinned at the foot, the way the Mac app keeps THIS MAC at the foot of
    /// its sidebar.
    private var thisDevice: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeading("THIS \(AppModel.deviceKind.uppercased())")
            Text(model.identity.fingerprint)
                .font(.system(size: Theme.fingerprint, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .accessibilityIdentifier("this-fingerprint")
            Text(model.config.deviceName)
                .font(.system(size: Theme.uiSmall))
                .foregroundStyle(Theme.textDim)
            Button("Pair a Mac…") { pairing = true }
                .buttonStyle(AccentButtonStyle())
                .padding(.top, 12)
                .disabled(model.pairingWith != nil)
                .accessibilityIdentifier("pair-button")
            Text("On the Mac, open OwnDesk and choose Show a code. Approve there only when it shows this \(AppModel.deviceKind)'s fingerprint.")
                .font(.system(size: Theme.uiSmall))
                .foregroundStyle(Theme.textFaint)
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .background(Theme.sidebar)
    }

    /// The log hides behind the status bar, the way the Mac app keeps its log on a toggle.
    private var logPanel: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: Theme.section, design: .monospaced))
                            .foregroundStyle(Theme.textDim)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(height: 160)
            .background(Theme.panel)
            .onAppear { reader.scrollTo(model.log.count - 1, anchor: .bottom) }
            .onChange(of: model.log.count) { _, count in reader.scrollTo(count - 1, anchor: .bottom) }
        }
    }

    private var statusBar: some View {
        HStack {
            Text(model.status)
                .lineLimit(1)
                .foregroundStyle(Theme.textDim)
                .accessibilityIdentifier("status-line")
            Spacer(minLength: 12)
            Text(model.identity.fingerprint)
                .foregroundStyle(Theme.textFaint)
                .font(.system(size: Theme.section, design: .monospaced))
        }
        .font(.system(size: Theme.section))
        .padding(.horizontal, 16)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(Theme.status.ignoresSafeArea(edges: .bottom))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showLog.toggle() } }
    }
}

/// One paired Mac: whether it answers, its name and fingerprint, and the address it will be tried at.
struct MacRow: View {
    @Environment(AppModel.self) private var model
    let mac: Peer

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.reachable.contains(mac.deviceId) ? Theme.online : Theme.textFaint)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name)
                    .font(.system(size: Theme.ui))
                    .foregroundStyle(Theme.text)
                Text(mac.fingerprint)
                    .font(.system(size: Theme.uiSmall, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                addressLine
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mac-\(mac.fingerprint)")
        .accessibilityHint("Opens its screen. Touch and hold for its address and for unpairing.")
    }

    /// Where it actually is beats where it last answered: an old address can be a Tailscale one that
    /// is dead right now while the Mac sits on the same Wi-Fi as this iPhone.
    @ViewBuilder private var addressLine: some View {
        let font = Font.system(size: Theme.section, design: .monospaced)
        if let pinned = model.pins[mac.deviceId] {
            Text("always \(pinned)").font(font).foregroundStyle(Theme.accent)
        } else if let live = model.onThisNetwork[mac.deviceId] {
            Text(live).font(font).foregroundStyle(Theme.online)
        } else {
            Text(model.candidates(for: mac).first ?? "no address").font(font).foregroundStyle(Theme.textFaint)
        }
    }
}
