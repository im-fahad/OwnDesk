import PRCControllerCore
import PRCProtocol
import SwiftUI

/// Editor-style layout: a fixed header, panels that come and go, and the remote screen filling
/// whatever is left. Only the screen is permanent; the sidebar and the log are toggles.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
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
    @EnvironmentObject var model: AppModel
    @Binding var showPairing: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Room for the traffic lights, which now sit inside this row.
            Spacer().frame(width: Theme.trafficLightInset)

            IconButton(systemName: "sidebar.leading", help: "Toggle hosts (⌘B)", isOn: model.showSidebar) {
                model.showSidebar.toggle()
            }
            IconButton(systemName: "text.alignleft", help: "Toggle log (⌘J)", isOn: model.showLog) {
                model.showLog.toggle()
            }

            Divider().frame(height: 16).overlay(Theme.border)

            title

            Spacer(minLength: 12)

            if model.isConnected {
                connectedControls
            } else {
                idleControls
            }
        }
        .padding(.trailing, 8)
        .frame(height: Theme.headerHeight)
        .background(Theme.header)
    }

    private var title: some View {
        HStack(spacing: 6) {
            if let id = model.selectedHostId, let host = model.store.host(id) {
                Circle()
                    .fill(model.isConnected ? Theme.online : (model.isBusy ? Theme.warn : Theme.textFaint))
                    .frame(width: 7, height: 7)
                Text(host.name).font(Theme.uiMedium).foregroundStyle(Theme.text)
                Text(host.fingerprint).font(Theme.monoSmall).foregroundStyle(Theme.textFaint)
            } else {
                Text("No host selected").font(Theme.ui).foregroundStyle(Theme.textDim)
            }
            Text(model.stateSummary).font(Theme.uiSecondary).foregroundStyle(Theme.textDim)
        }
        .lineLimit(1)
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
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.content, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border))
                .frame(width: 190)

            Button(model.isBusy ? "Connecting…" : "Connect") { model.connect() }
                .buttonStyle(HeaderButtonStyle(tint: Theme.accent))
                .disabled(model.selectedHostId == nil || model.isBusy)
        }
    }
}

struct HeaderButtonStyle: ButtonStyle {
    var tint: Color
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(hovering || configuration.isPressed ? tint.opacity(0.16) : tint.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(tint.opacity(0.35)))
            .onHover { hovering = $0 }
    }
}

// MARK: - Sidebar

struct SidebarPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var showPairing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Hosts")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.hosts) { host in
                        HostRow(host: host, isSelected: model.selectedHostId == host.deviceId)
                            .onTapGesture { model.selectedHostId = host.deviceId }
                            .contextMenu {
                                Button("Connect") { model.selectedHostId = host.deviceId; model.connect() }
                                Divider()
                                Button("Forget \(host.fingerprint)", role: .destructive) { model.forget(host.deviceId) }
                            }
                    }
                    if model.hosts.isEmpty {
                        Text("No paired hosts yet.")
                            .font(Theme.uiSecondary).foregroundStyle(Theme.textFaint)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    let unpaired = model.discovered.filter { d in !model.hosts.contains { $0.deviceId == d.deviceId } }
                    if !unpaired.isEmpty {
                        sectionHeader("Nearby, not paired").padding(.top, 8)
                        ForEach(unpaired) { d in
                            Text(d.name)
                                .font(Theme.uiSecondary).foregroundStyle(Theme.textFaint)
                                .padding(.horizontal, 12).padding(.vertical, 3)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Spacer(minLength: 0)
            Rectangle().fill(Theme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("THIS MAC").font(Theme.section).foregroundStyle(Theme.textFaint).tracking(0.5)
                Text(model.fingerprint).font(Theme.monoLarge).foregroundStyle(Theme.text)
                Button("Pair with a host…") { showPairing = true }
                    .buttonStyle(HeaderButtonStyle(tint: Theme.accent))
            }
            .padding(12)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.section).tracking(0.5)
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
    }
}

struct HostRow: View {
    @EnvironmentObject var model: AppModel
    let host: PairedHost
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.discoveredHost(for: host.deviceId) != nil ? Theme.online : Theme.textFaint)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name).font(Theme.ui).foregroundStyle(Theme.text).lineLimit(1)
                // The fingerprint is what tells two entries for the same Mac apart, so it has to be
                // readable rather than decorative.
                Text(host.fingerprint).font(Theme.monoSmall).foregroundStyle(Theme.textDim)
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
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Color.black
            // Kept in the hierarchy at all times so the renderer is attached once and the stream
            // survives every panel toggle.
            VideoView()
            if !model.isConnected { placeholder }
            if model.showTextField { textOverlay }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "display").font(.system(size: 34)).foregroundStyle(Theme.textFaint)
            Text(model.placeholderTitle).font(Theme.ui).foregroundStyle(Theme.textDim)
            if let detail = model.placeholderDetail {
                Text(detail).font(Theme.uiSecondary).foregroundStyle(Theme.textFaint)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            if !model.isBusy, model.selectedHostId != nil {
                Button("Connect") { model.connect() }
                    .buttonStyle(HeaderButtonStyle(tint: Theme.accent))
                    .padding(.top, 2)
            }
        }
        .padding(28)
        .background(Theme.content.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
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
    @EnvironmentObject var model: AppModel

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
    @EnvironmentObject var model: AppModel

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
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair with a host").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Text("On the Mac Mini, start pairing and paste the payload it shows here. Approve there only if it displays this Mac's fingerprint:")
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
            if !model.pairingStatus.isEmpty {
                Text(model.pairingStatus).font(Theme.uiSecondary).foregroundStyle(Theme.warn)
            }
            HStack {
                Spacer()
                Button("Close") { isPresented = false }.buttonStyle(HeaderButtonStyle(tint: Theme.textDim))
                Button(model.isPairing ? "Waiting for approval…" : "Pair") { model.pair() }
                    .buttonStyle(HeaderButtonStyle(tint: Theme.accent))
                    .disabled(model.isPairing || model.pairingText.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.header)
        .preferredColorScheme(.dark)
    }
}
