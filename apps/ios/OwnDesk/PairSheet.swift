import OwnDeskControllerCore
import OwnDeskPeers
import SwiftUI

/// Pairing: scan the code a Mac shows, or paste it. Either way the same text reaches the same
/// pairing client, and the person approves on the Mac after comparing fingerprints.
struct PairSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var scanning = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Scan the code the Mac is showing, or paste it. Approve on the Mac only when it shows **\(model.identity.fingerprint)**.")
                        .font(.system(size: Theme.uiSecondary))
                        .foregroundStyle(Theme.textDim)

                    Button { scanning = true } label: {
                        Label("Scan a code", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!QRScanner.isAvailable)
                    .accessibilityIdentifier("scan-button")
                    if !QRScanner.isAvailable {
                        Text("There is no camera here, so paste the code instead.")
                            .font(.system(size: Theme.uiSmall))
                            .foregroundStyle(Theme.textFaint)
                    }

                    SectionHeading("OR PASTE IT")
                    TextEditor(text: $code)
                        .font(.system(size: Theme.uiSecondary, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .scrollContentBackground(.hidden)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(height: 120)
                        .padding(6)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("code-field")
                    if let problem {
                        Text(problem)
                            .font(.system(size: Theme.uiSmall))
                            .foregroundStyle(Theme.danger)
                            .accessibilityIdentifier("pair-problem")
                    }
                    HStack {
                        // Pastes without the system asking whether this app may read the clipboard.
                        PasteButton(payloadType: String.self) { strings in
                            code = strings.first ?? ""
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.roundedRectangle)
                        Spacer()
                        Button("Pair") { pair(code) }
                            .font(.system(size: Theme.ui, weight: .semibold))
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("pair-confirm")
                    }
                    Text("On the Mac: OwnDesk → Pair a Mac… → Show a code.")
                        .font(.system(size: Theme.uiSmall))
                        .foregroundStyle(Theme.textFaint)
                }
                .padding(16)
            }
            .background(Theme.content)
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $scanning) {
            QRScanner(onCode: { text in
                scanning = false
                model.note("read a code from the camera")
                pair(text)
            }, onCancel: { scanning = false })
            .ignoresSafeArea()
        }
    }

    /// Checked here first, so a wrong paste is answered in the sheet the person is looking at,
    /// rather than by an alert that would have to wait for the sheet to close.
    private func pair(_ text: String) {
        guard (try? PairingClient.parse(text)) != nil else {
            problem = "That is not an OwnDesk pairing code. Copy or scan the code the Mac shows under Pair a Mac… → Show a code."
            return
        }
        problem = nil
        model.pair(code: text)
        dismiss()
    }
}

/// Where a Mac is tried first. It matters when the same Mac is reachable by more than one route: at
/// home it answers on the local network, and away from home only a Tailscale address reaches it.
struct AddressSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mac: Peer
    @State private var typed = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tap an address to use it, or type one below. Tapping fills the field, so a port or a digit can still be corrected first.")
                        .font(.system(size: Theme.uiSecondary))
                        .foregroundStyle(Theme.textDim)
                    ForEach(model.candidates(for: mac), id: \.self) { address in
                        Button { typed = address } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(address)
                                    .font(.system(size: Theme.uiSecondary, design: .monospaced))
                                    .foregroundStyle(Theme.text)
                                let note = model.note(for: address, of: mac)
                                Text(note)
                                    .font(.system(size: Theme.section))
                                    .foregroundStyle(note == "on this network now" ? Theme.online : Theme.textFaint)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    SectionHeading("OR TYPE ONE")
                    TextField("100.64.0.10:47500", text: $typed)
                        .font(.system(size: Theme.uiSecondary, design: .monospaced))
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(10)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                    Text("Leave it empty to use whichever address answers.")
                        .font(.system(size: Theme.uiSmall))
                        .foregroundStyle(Theme.textFaint)
                }
                .padding(16)
            }
            .background(Theme.content)
            .navigationTitle("Address for \(mac.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use it") {
                        model.setPin(typed, for: mac)
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { typed = model.pins[mac.deviceId] ?? model.candidates(for: mac).first ?? "" }
    }
}
