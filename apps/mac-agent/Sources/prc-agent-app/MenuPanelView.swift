import PRCAgentCore
import PRCProtocol
import SwiftUI

struct MenuPanelView: View {
    @EnvironmentObject var model: AgentAppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            Toggle("Remote Access", isOn: Binding(get: { model.remoteAccess }, set: { model.setRemoteAccess($0) }))
                .toggleStyle(.switch)
            permissions
            Divider()
            sessionSection
            Divider()
            devicesSection
            Divider()
            HStack {
                Button("Pair New Device…") {
                    openWindow(id: "pairing")
                    model.startPairing()
                }
                .disabled(!model.remoteAccess)
                Spacer()
                Button(showSettings ? "Hide Settings" : "Settings") { showSettings.toggle() }
            }
            if showSettings { settings }
            if !model.lastMessage.isEmpty {
                Text(model.lastMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Divider()
            HStack {
                Text("PRC Agent 0.1.0").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { model.quit() }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.config.hostName).font(.headline)
            Text("fingerprint \(model.fingerprint)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            if model.remoteAccess {
                Text(model.port == 0 ? "starting…" : "listening on \(model.addresses.first ?? "port \(model.port)")").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("remote access is off: not listening, not advertised").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var permissions: some View {
        if !model.screenRecording {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Screen Recording not granted").font(.caption)
                Spacer()
                Button("Open Settings") { model.openPrivacySettings("Privacy_ScreenCapture") }.font(.caption)
            }
        }
        if !model.accessibility {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Accessibility not granted").font(.caption)
                Spacer()
                Button("Open Settings") { model.openPrivacySettings("Privacy_Accessibility") }.font(.caption)
            }
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Active session").font(.caption).foregroundStyle(.secondary)
            if let s = model.session {
                HStack {
                    Circle().fill(s.path == nil ? Color.orange : Color.green).frame(width: 8, height: 8)
                    VStack(alignment: .leading) {
                        Text(s.deviceName)
                        Text("\(s.path ?? s.phase), since \(s.since.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect") { model.endSession() }
                }
            } else {
                Text("none").foregroundStyle(.secondary)
            }
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Trusted devices").font(.caption).foregroundStyle(.secondary)
            if model.devices.isEmpty {
                Text("none paired yet").foregroundStyle(.secondary)
            }
            ForEach(model.devices, id: \.deviceId) { d in
                HStack {
                    Image(systemName: d.type == .android ? "iphone" : d.type == .mac ? "laptopcomputer" : "globe")
                    VStack(alignment: .leading) {
                        Text(d.name)
                        Text("\(d.fingerprint)  ·  \(lastSeen(d))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke") { model.revoke(d.deviceId) }
                }
            }
        }
    }

    private func lastSeen(_ d: TrustedDevice) -> String {
        guard let t = d.lastSeen else { return "never connected" }
        return "seen " + Date(timeIntervalSince1970: Double(t) / 1000).formatted(.relative(presentation: .named))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Host name", text: $model.hostNameSetting)
            Stepper("Idle timeout: \(model.idleTimeoutMinutes) min", value: $model.idleTimeoutMinutes, in: 5...720, step: 5)
            HStack {
                Text("Identity: \(model.config.identityFile == nil ? "Keychain / Secure Enclave" : "dev file")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save") { model.saveSettings() }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}
