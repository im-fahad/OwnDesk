import SwiftUI

/// Another device asks to open terminals on this Mac. Allowing it adds that device's SSH key to this
/// account's `~/.ssh/authorized_keys`, which is a shell with everything this account can do, so it is
/// a click here and never anything a script can answer.
struct TerminalKeyRequestSheet: View {
    @EnvironmentObject var model: AppState
    let request: TerminalKeyRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Terminal access", systemImage: "terminal").font(.headline).foregroundStyle(Theme.text)
            Text("\"\(request.deviceName)\" asks to open terminals on this Mac, logged in as \(request.username).")
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Device").font(Theme.uiSecondary).foregroundStyle(Theme.textDim).frame(width: 52, alignment: .leading)
                Text(request.deviceFingerprint).font(.system(size: 18, design: .monospaced)).foregroundStyle(Theme.text)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Its key").font(Theme.uiSecondary).foregroundStyle(Theme.textDim).frame(width: 52, alignment: .leading)
                Text(request.keyFingerprint).font(Theme.monoSmall).foregroundStyle(Theme.textDim).textSelection(.enabled)
            }
            Text("Allowing it adds that key to ~/.ssh/authorized_keys, so it can run anything this account can, through Remote Login. Unpairing the device takes the key away again. Allow it only if you asked for this on that device just now.")
                .font(Theme.uiSecondary).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Deny") { model.answerTerminalKey(allow: false) }.buttonStyle(HeaderButtonStyle(tint: Theme.danger))
                Button("Allow") { model.answerTerminalKey(allow: true) }.buttonStyle(HeaderButtonStyle(tint: Theme.accent))
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.header)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }
}
