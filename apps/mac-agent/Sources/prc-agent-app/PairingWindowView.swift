import PRCAgentCore
import SwiftUI

struct PairingWindowView: View {
    @EnvironmentObject var model: AgentAppModel
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair a new device").font(.title2)
            if let request = model.pendingRequest {
                approval(request)
            } else if let pairing = model.pairing {
                qrSection(pairing)
            } else if let outcome = model.pairingOutcome {
                Text(outcome).font(.headline)
                Button("Pair another device") { model.startPairing() }
            } else {
                Text("Remote access must be on to pair.").foregroundStyle(.secondary)
                Button("Start pairing") { model.startPairing() }.disabled(!model.remoteAccess)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onReceive(tick) { now = $0 }
    }

    private func qrSection(_ pairing: AgentAppModel.PairingInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan this with the controller, or copy the text and paste it there.")
            HStack(alignment: .top, spacing: 16) {
                if let image = pairing.image {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                        .background(Color.white).cornerRadius(6)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("This Mac's fingerprint").font(.caption).foregroundStyle(.secondary)
                    Text(model.fingerprint).font(.system(.title3, design: .monospaced))
                    Text("Expires in \(max(0, Int(pairing.expiresAt.timeIntervalSince(now)))) s").font(.caption).foregroundStyle(.secondary)
                    Button("Copy payload text") { model.copyPayload() }
                    Button("Cancel") { model.cancelPairing() }
                }
            }
            Text("When the controller sends its request, its fingerprint appears here. Approve only if the controller shows the same fingerprint.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func approval(_ request: AgentAppModel.PendingRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pairing request", systemImage: "person.badge.key")
                .font(.headline)
            Text("\"\(request.name)\" (\(request.type.rawValue)) wants to control this Mac.")
            VStack(alignment: .leading, spacing: 4) {
                Text("Controller fingerprint").font(.caption).foregroundStyle(.secondary)
                Text(request.fingerprint).font(.system(.largeTitle, design: .monospaced)).bold()
            }
            Text("Compare with the fingerprint shown on that device. If they differ, deny: someone else on this network is trying to pair.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Deny", role: .destructive) { model.denyPairing() }
                Button("Approve") { model.approvePairing() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
