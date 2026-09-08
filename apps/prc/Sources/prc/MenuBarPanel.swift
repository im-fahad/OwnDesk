import PRCPeers
import SwiftUI

/// The compact view for a Mac with no window open: is anyone controlling it, and the switch that
/// decides whether anyone may.
struct MenuBarPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.config.deviceName).font(.headline)
                Text("fingerprint \(state.fingerprint)").font(Theme.monoSmall).foregroundStyle(.secondary)
            }
            Divider()

            Toggle("Let other Macs control this one", isOn: Binding(get: { state.hosting }, set: { state.setHosting($0) }))
                .toggleStyle(.switch)
            if state.hosting {
                Text(state.hostPort == 0 ? "starting…" : "listening on \(state.hostAddresses.first ?? "port \(state.hostPort)")")
                    .font(.caption).foregroundStyle(.secondary)
                permissions
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Incoming").font(.caption).foregroundStyle(.secondary)
                if let s = state.incoming {
                    HStack {
                        Circle().fill(s.path == nil ? Color.orange : Color.green).frame(width: 8, height: 8)
                        VStack(alignment: .leading) {
                            Text(s.deviceName)
                            Text(s.path ?? s.phase).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Disconnect") { state.endIncoming() }
                    }
                } else {
                    Text(state.hosting ? "nobody is connected" : "hosting is off").foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack {
                Button("Open PRC…") { openWindow(id: PRCApp.windowID) }
                Spacer()
                Button("Quit") { state.quit() }
            }
            if !state.lastMessage.isEmpty {
                Text(state.lastMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder private var permissions: some View {
        if !state.screenRecording {
            permissionRow("Screen Recording not granted", pane: "Privacy_ScreenCapture")
        }
        if !state.accessibility {
            permissionRow("Accessibility not granted", pane: "Privacy_Accessibility")
        }
        if !state.screenRecording || !state.accessibility {
            Text("If the switch in System Settings is already on, it belongs to a previous build: remove PRC from that list, grant again when asked, then quit and reopen.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func permissionRow(_ title: String, pane: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(title).font(.caption)
            Spacer()
            Button("Open Settings") { state.openPrivacySettings(pane) }.font(.caption)
        }
    }
}
