import OwnDeskPeers
import OwnDeskTerminal
import SwiftUI
import UIKit

/// How to log in to a Mac's terminal, asked the first time and editable after.
///
/// The terminal is the Mac's own SSH server, so two things have to be true on the Mac: Remote Login
/// is on, and it knows this device. The second is either this device's key in `authorized_keys`,
/// which the sheet makes a single paste, or the account's password, asked for each time.
struct TerminalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mac: Peer
    @State private var username = ""
    @State private var port = "22"
    @State private var copied: String?
    @State private var forgotten = false
    /// The pinned key as the sheet opened, kept after Forget so the confirmation has somewhere to show.
    @State private var shownPin: SSHHostKey?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("The terminal is \(mac.name)'s own SSH server. Turn on **Remote Login** there first: System Settings → General → Sharing → Remote Login. Behind its ⓘ, **Allow full disk access for remote users** lets the shell read Documents, Desktop and Downloads.")
                        .font(.system(size: Theme.uiSecondary))
                        .foregroundStyle(Theme.textDim)

                    SectionHeading("LOG IN AS")
                    field("user name on \(mac.name)", text: $username, id: "ssh-user")
                    HStack(spacing: 8) {
                        Text("Port")
                            .font(.system(size: Theme.uiSecondary))
                            .foregroundStyle(Theme.textDim)
                        field("22", text: $port, id: "ssh-port")
                            .keyboardType(.numberPad)
                            .frame(width: 90)
                        Spacer()
                    }
                    Text("The short name of the account, as `whoami` prints it in Terminal on the Mac.")
                        .font(.system(size: Theme.uiSmall))
                        .foregroundStyle(Theme.textFaint)

                    SectionHeading("THIS \(AppModel.deviceKind.uppercased())'S KEY")
                    Text("With this key on \(mac.name), the terminal opens without a password. Without it, you are asked for the account's password each time.")
                        .font(.system(size: Theme.uiSmall))
                        .foregroundStyle(Theme.textDim)
                    Text(model.sshKeyLine)
                        .font(.system(size: Theme.section, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("ssh-public-key")
                        .accessibilityValue(model.sshKeyLine)
                    HStack {
                        copyButton("Copy the key", model.sshKeyLine)
                        copyButton("Copy a command for the Mac", model.sshKeyCommand)
                    }
                    Text(copied.map { "\($0) Paste it into Terminal on \(mac.name)." } ?? "The command adds the key to ~/.ssh/authorized_keys on \(mac.name).")
                        .font(.system(size: Theme.uiSmall))
                        .foregroundStyle(copied == nil ? Theme.textFaint : Theme.online)
                    Text("Key \(model.sshKey.fingerprint), kept in this \(AppModel.deviceKind)'s \(model.sshKey.storage == "Secure Enclave" ? "Secure Enclave" : "storage").")
                        .font(.system(size: Theme.section, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)

                    if let pinned = shownPin {
                        SectionHeading("\(mac.name.uppercased())'S SSH KEY")
                        Text("\(pinned.type)  \(pinned.fingerprint)")
                            .font(.system(size: Theme.section, design: .monospaced))
                            .foregroundStyle(Theme.textDim)
                            .textSelection(.enabled)
                        Button(forgotten ? "Forgotten" : "Forget it", role: .destructive) { model.forgetHostKey(of: mac); forgotten = true }
                            .font(.system(size: Theme.uiSecondary))
                            .disabled(forgotten)
                        Text(forgotten ? "The next terminal asks whether to trust its key again."
                                       : "Only if the Mac's key really changed, as after reinstalling macOS. The next terminal asks again.")
                            .font(.system(size: Theme.uiSmall))
                            .foregroundStyle(forgotten ? Theme.online : Theme.textFaint)
                    }
                }
                .padding(16)
            }
            .background(Theme.content)
            .navigationTitle("Terminal on \(mac.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") { open() }
                        .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || Int(port) == nil)
                        .accessibilityIdentifier("terminal-open")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            let saved = model.terminalSettings[mac.deviceId]
            username = saved?.username ?? ""
            port = String(saved?.port ?? 22)
            shownPin = model.knownHosts.pinned(mac.deviceId)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, id: String) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: Theme.uiSecondary, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(10)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier(id)
    }

    private func copyButton(_ title: String, _ text: String) -> some View {
        Button(title) {
            UIPasteboard.general.string = text
            copied = title == "Copy the key" ? "Key copied." : "Command copied."
        }
        .font(.system(size: Theme.uiSecondary))
        .buttonStyle(.bordered)
    }

    private func open() {
        let settings = TerminalSettings(username: username.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 22)
        model.saveTerminalSettings(settings, for: mac)
        dismiss()
        // Once the sheet is gone: a full screen cover cannot come up while it is still closing.
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            model.openTerminal(mac)
        }
    }
}
