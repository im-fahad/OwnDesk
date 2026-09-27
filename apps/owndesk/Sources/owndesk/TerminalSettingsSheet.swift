import AppKit
import OwnDeskPeers
import SwiftUI

/// How to log in to another Mac's terminal, asked the first time and editable after.
///
/// The terminal is that Mac's own SSH server, so two things have to be true there: Remote Login is
/// on, and it knows this Mac. The second is either this Mac's key in its `authorized_keys`, which
/// the sheet makes a single paste, or the account's password, asked for each time.
struct TerminalSettingsSheet: View {
    @EnvironmentObject var model: AppState
    let mac: Peer
    @State private var username = ""
    @State private var port = "22"
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Terminal on \(mac.name)").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Text("The terminal is \(mac.name)'s own SSH server. Turn on Remote Login there first: System Settings → General → Sharing → Remote Login. Behind its ⓘ, Allow full disk access for remote users lets the shell read Documents, Desktop and Downloads.")
                .font(Theme.uiSecondary).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            heading("LOG IN AS")
            HStack(spacing: 8) {
                field("user name on \(mac.name)", text: $username)
                Text("Port").font(Theme.uiSecondary).foregroundStyle(Theme.textDim)
                field("22", text: $port).frame(width: 70)
            }
            Text("The short name of the account, as whoami prints it in Terminal on \(mac.name).")
                .font(Theme.uiSmall).foregroundStyle(Theme.textFaint)

            heading("THIS MAC'S KEY")
            Text("With this key on \(mac.name), the terminal opens without a password. Without it, you are asked for the account's password each time.")
                .font(Theme.uiSmall).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.sshKeyLine)
                .font(Theme.monoSmall).foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.content, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            HStack(spacing: 8) {
                Button("Copy the key") { copy(model.sshKeyLine, "Key copied.") }.buttonStyle(HeaderButtonStyle(tint: Theme.accent))
                Button("Copy a command for \(mac.name)") { copy(model.sshKeyCommand, "Command copied.") }.buttonStyle(HeaderButtonStyle(tint: Theme.accent))
                Spacer()
            }
            Text(copied.map { "\($0) Paste it into Terminal on \(mac.name)." } ?? "The command adds the key to ~/.ssh/authorized_keys on \(mac.name).")
                .font(Theme.uiSmall).foregroundStyle(copied == nil ? Theme.textFaint : Theme.online)
            Text("Key \(model.sshKey.fingerprint), kept in this Mac's \(model.sshKey.storage == "Secure Enclave" ? "Secure Enclave" : "storage").")
                .font(Theme.monoSmall).foregroundStyle(Theme.textFaint)

            if let pinned = model.knownHosts.pinned(mac.deviceId) {
                heading("\(mac.name.uppercased())'S SSH KEY")
                Text("\(pinned.type)  \(pinned.fingerprint)")
                    .font(Theme.monoSmall).foregroundStyle(Theme.textDim)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("Forget it") { model.forgetHostKey(of: mac) }.buttonStyle(HeaderButtonStyle(tint: Theme.danger))
                    Text("Only if the Mac's key really changed, as after reinstalling macOS. The next terminal asks again.")
                        .font(Theme.uiSmall).foregroundStyle(Theme.textFaint)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { model.terminalSetup = nil }.buttonStyle(HeaderButtonStyle(tint: Theme.textDim))
                Button("Open") { open() }
                    .buttonStyle(HeaderButtonStyle(tint: Theme.accent))
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || Int(port) == nil)
            }
        }
        .padding(20)
        .frame(width: 600)
        .background(Theme.header)
        .preferredColorScheme(.dark)
        .onAppear {
            let saved = model.terminalSettings[mac.deviceId]
            username = saved?.username ?? ""
            port = String(saved?.port ?? 22)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(Theme.sidebarSection).tracking(0.5).foregroundStyle(Theme.textFaint).padding(.top, 4)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(Theme.mono)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.content, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border))
    }

    private func copy(_ text: String, _ note: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = note
    }

    private func open() {
        let settings = TerminalSettings(username: username.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 22)
        model.saveTerminalSettings(settings, for: mac)
        model.terminalSetup = nil
        model.openTerminal(mac)
    }
}
