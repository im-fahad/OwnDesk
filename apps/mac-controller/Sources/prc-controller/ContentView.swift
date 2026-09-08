import PRCControllerCore
import PRCProtocol
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showPairing = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(isPresented: $showPairing) { PairingSheet(isPresented: $showPairing) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $model.selectedHostId) {
                Section("Paired hosts") {
                    ForEach(model.hosts) { host in
                        HStack {
                            Circle().fill(model.discoveredHost(for: host.deviceId) != nil ? Color.green : Color.gray).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(host.name)
                                // The fingerprint is what tells two entries for the same Mac apart.
                                // Without it, forgetting the live one instead of a stale one is easy.
                                Text(host.fingerprint).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                                Text(model.discoveredHost(for: host.deviceId) != nil ? "on this network" : host.addresses.first ?? "no address")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .tag(host.deviceId)
                        .contextMenu { Button("Forget \(host.fingerprint)", role: .destructive) { model.forget(host.deviceId) } }
                    }
                }
                if !model.discovered.filter({ d in !model.hosts.contains { $0.deviceId == d.deviceId } }).isEmpty {
                    Section("Nearby, not paired") {
                        ForEach(model.discovered.filter { d in !model.hosts.contains { $0.deviceId == d.deviceId } }) { d in
                            Text(d.name).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("This Mac").font(.caption).foregroundStyle(.secondary)
                Text(model.fingerprint).font(.system(.title3, design: .monospaced))
                Button("Pair with a host…") { showPairing = true }
            }
            .padding(12)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VideoView()
            Divider()
            logView
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if let id = model.selectedHostId, let host = model.store.host(id) {
                Text(host.name).font(.headline)
                Text(host.fingerprint).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            } else {
                Text("No host selected").foregroundStyle(.secondary)
            }
            Text(AppModel.describe(model.state)).foregroundStyle(.secondary)
            if let rtt = model.rtt { Text("RTT \(Int(rtt)) ms").font(.caption).foregroundStyle(.secondary) }
            if let d = model.display {
                let stream = model.videoSize == .zero ? "" : "  ← \(Int(model.videoSize.width))×\(Int(model.videoSize.height))"
                Text("\(d.width_px)×\(d.height_px)\(stream)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isConnected {
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
                    Text(model.quality == .auto ? "Quality" : model.quality.label)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Toggle("Send input", isOn: $model.sendInput).toggleStyle(.checkbox)
                Button("⌘Tab") { model.sendShortcut("Tab", modifiers: [.meta]) }
                Button("⌘Space") { model.sendShortcut("Space", modifiers: [.meta]) }
                Button("⌘Q") { model.sendShortcut("KeyQ", modifiers: [.meta]) }
                TextField("Type text to send", text: $model.textToSend).frame(width: 180).onSubmit { model.sendText() }
                Button("Send") { model.sendText() }
                Button("Disconnect") { model.disconnect() }
            } else {
                TextField("address override, e.g. 192.168.1.20:47500", text: $model.manualAddress).frame(width: 240)
                Button(model.isBusy ? "Connecting…" : "Connect") { model.connect() }
                    .disabled(model.selectedHostId == nil || model.isBusy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
    }

    private var logView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(height: 120)
    }
}

struct PairingSheet: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair with a host").font(.title2)
            Text("On the Mac Mini, start pairing and paste the payload it shows here. Then approve on the Mac Mini only if it displays this Mac's fingerprint:")
            Text(model.fingerprint).font(.system(.title, design: .monospaced))
            TextEditor(text: $model.pairingText)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 120)
                .border(.secondary.opacity(0.3))
            TextField("Address override (optional), e.g. 192.168.1.20:47500", text: $model.pairingAddress)
            if !model.pairingStatus.isEmpty { Text(model.pairingStatus).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Close") { isPresented = false }
                Button(model.isPairing ? "Waiting for approval…" : "Pair") { model.pair() }
                    .disabled(model.isPairing || model.pairingText.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
