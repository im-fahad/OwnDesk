import OwnDeskControllerCore
import OwnDeskPeers
import SwiftUI

/// Which address the selected Mac is tried at first, shown beside Connect. Most Macs need no
/// choice, so it reads "Any address" until one is made.
struct AddressChip: View {
    let peer: Peer
    let pinned: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "network").font(.system(size: 10))
                Text(pinned ?? "Any address").font(Theme.uiSecondary).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(pinned == nil ? Theme.textDim : Theme.text)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(maxWidth: 190)
            .background(hovering ? Theme.content : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(pinned == nil
              ? "\(peer.name) is reached at whichever address answers. Click to choose one."
              : "\(peer.name) is tried at \(pinned!) first. Click to change.")
    }
}

/// Where a Mac is tried first. It matters when the same Mac is reachable by more than one route:
/// at home it answers on the local network, and away from home only a Tailscale address reaches it.
/// The same sheet as on the phones.
struct AddressSheet: View {
    @EnvironmentObject var model: AppState
    let mac: Peer
    @State private var typed = ""
    @State private var live: String?

    private var candidates: [String] {
        var seen = Set<String>()
        return ([model.addressPins[mac.deviceId], live].compactMap { $0 } + mac.addresses)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Address for \(mac.name)").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Click an address to use it, or type one below. Clicking fills the field, so a port or a digit can still be corrected first. If the chosen address does not answer, the others are still tried.")
                .font(Theme.uiSecondary).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            if model.discoveredPeer(for: mac.deviceId) != nil {
                HStack(spacing: 6) {
                    Circle().fill(Theme.online).frame(width: 6, height: 6)
                    Text("\(mac.name) is on this network now, so any address will find it here.")
                        .font(Theme.uiSmall).foregroundStyle(Theme.textDim)
                }
            }
            if candidates.isEmpty {
                Text("No addresses known yet. Type one below.").font(Theme.uiSecondary).foregroundStyle(Theme.textFaint)
            }
            ForEach(candidates, id: \.self) { address in
                AddressRow(address: address,
                           note: AppState.routeNote(for: address, live: live),
                           isLive: address == live,
                           isPicked: address == typed.trimmingCharacters(in: .whitespaces)) { typed = address }
            }

            Text("OR TYPE ONE").font(Theme.sidebarSection).tracking(0.5).foregroundStyle(Theme.textFaint).padding(.top, 6)
            TextField("host:port, such as 100.64.0.10:47500", text: $typed)
                .textFieldStyle(.plain)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Theme.content, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border))
                .onSubmit(useIt)

            HStack {
                Button("Use any address") {
                    model.setAddressPin(nil, for: mac.deviceId)
                    model.choosingAddress = nil
                }
                .buttonStyle(HeaderButtonStyle(tint: Theme.textDim))
                .disabled(model.addressPins[mac.deviceId] == nil)
                Spacer()
                Button("Cancel") { model.choosingAddress = nil }
                    .buttonStyle(HeaderButtonStyle(tint: Theme.textDim))
                    .keyboardShortcut(.cancelAction)
                Button("Use it", action: useIt)
                    .buttonStyle(HeaderButtonStyle(tint: Theme.accent))
                    .disabled(!isUsable)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.header)
        .preferredColorScheme(.dark)
        .onAppear { typed = model.addressPins[mac.deviceId] ?? "" }
        .task { live = await model.liveAddress(of: mac) }
    }

    private var isUsable: Bool {
        let clean = typed.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty || Endpoints.url(for: clean) != nil
    }

    private func useIt() {
        guard isUsable else { return }
        model.setAddressPin(typed, for: mac.deviceId)
        model.choosingAddress = nil
    }
}

private struct AddressRow: View {
    let address: String
    let note: String
    let isLive: Bool
    let isPicked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(address).font(Theme.monoSmall).foregroundStyle(Theme.text)
                    Text(note).font(Theme.uiSmall).foregroundStyle(isLive ? Theme.online : Theme.textFaint)
                }
                Spacer()
                if isPicked { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Theme.content : Theme.sidebar, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isPicked ? Theme.accent.opacity(0.6) : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
