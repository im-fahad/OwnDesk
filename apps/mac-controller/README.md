# PRC Mac controller

The MacBook side of PRC: discovers hosts, pairs, authenticates, receives the screen over WebRTC,
and forwards mouse, scroll, keyboard, and text. Spec sections 4.2, 7, 8, 10, 13.

Three targets:

- `PRCControllerCore`: discovery, pairing, the session state machine with reconnection, the
  WebRTC offerer, and input mapping.
- `prc-controller`: the SwiftUI app.
- `prc-controller-cli`: the same core without a window, for scripts and remote testing.

## Build and run

```sh
cd apps/mac-controller
swift build
swift run prc-controller --file-identity
```

| Flag | Effect |
|---|---|
| `--name <text>` | Name shown to hosts when pairing. Default: this Mac's name. |
| `--data-dir <path>` | Where paired hosts live. Default `~/Library/Application Support/PRC Controller` |
| `--file-identity` | **Development only.** Software identity in `<data-dir>/identity.key` instead of the Keychain and Secure Enclave, so rebuilt ad-hoc binaries do not prompt for Keychain access. |

No macOS permissions are needed. From the repo root, `scripts/build-apps.sh controller` produces
`dist/PRC Controller.app` (ad-hoc signed; no certificate is needed for personal use) and
`scripts/install-controller.sh` copies it to `~/Applications`. An ad-hoc signed build keeps its
Secure Enclave backed identity in its data folder rather than the Keychain, so rebuilds do not
prompt; see the agent README for the reasoning.

## Using it

1. On the Mac Mini, run the agent and type `pair`. Copy the JSON line it prints.
2. In the controller, click **Pair with a host…**, paste the JSON, and click **Pair**.
3. The agent prints the controller's fingerprint. The sheet shows this Mac's fingerprint. If they
   match, type `y` on the agent. The host appears in the sidebar.
4. Hosts advertised on the current network show a green dot. Select one and click **Connect**. On
   another network, type the host's address in the override field first, for example a Tailscale
   address such as `100.64.0.10:47500`.
5. Move the pointer over the video to control the host. While the pointer is over the video and the
   window is active, every key including Cmd+Q and Cmd+W goes to the host. Move the pointer off the
   video to get your keyboard back.

Toolbar buttons send the shortcuts macOS never lets a window see: Cmd+Tab, Cmd+Space, Cmd+Q. The
text field sends a whole string as one `text` event, useful for passwords and non-Latin input.

## Headless CLI, for scripts and remote testing

```sh
swift run prc-controller-cli discover                       # hosts advertised on this network
swift run prc-controller-cli pair --qr-file qr.json          # then approve on the host
swift run prc-controller-cli connect <host id prefix> --seconds 20 --probe-input
swift run prc-controller-cli hosts
```

`prc-controller-cli` uses the same core as the app with no window, and a file identity by default
because an SSH session has no Keychain UI. `connect` prints a checklist: discovery, authentication,
path, frames per second and resolution each second, ping round trip, display info, a one-pixel
relative mouse move out and back when `--probe-input` is given, and a clean disconnect.

It is how the two-device test was run: the agent on the Mac Mini, the CLI on a MacBook over SSH,
with the pairing fingerprint compared on both sides before approval. Keep `--data-dir` outside any
folder you sync to the other machine.

## Driving the app from a script

Like the agent, the app opens a same-user control channel (`control.json` in its data folder).
`prc-controller-cli app` talks to it:

```sh
prc-controller-cli app status
prc-controller-cli app pair @payload.json [address]   # the app sends PAIR_REQUEST; approve on the host
prc-controller-cli app connect <host name | id prefix> [address]
prc-controller-cli app disconnect | hosts | forget <host> | quit
```

## Reconnection

Media loss triggers an ICE restart on the existing session. Signaling loss reconnects and sends
`SESSION_RESUME`; a rejected resume falls back to full authentication, never to re-pairing. After
60 seconds without success the session ends. All of it is signed and verified like the first
connection (spec section 10).

## What is where

| File | Role |
|---|---|
| `HostDiscovery.swift` | Bonjour browser for `_prc._tcp` with TXT records |
| `Endpoints.swift` | Address parsing and Bonjour service resolution to a `ws://` URL |
| `SignalingClient.swift` | WebSocket client on Network.framework |
| `PairingClient.swift` | PAIR_REQUEST with proof, PAIR_RESULT verified against the QR's key hash |
| `SessionClient.swift` | Authentication, offer, ICE, keepalive, reconnection, teardown |
| `WebRTCClient.swift` | Peer connection as offerer, data channels, remote track, path detection |
| `InputMapper.swift` | Letterbox-aware coordinate mapping, key code inversion, modifier and scroll mapping |
| `HostStore.swift` | Paired hosts on disk |
| `../prc-controller/VideoView.swift` | Metal video view plus the input overlay and keyboard capture |

## Tests

```sh
swift test
```

Eleven tests. Geometry, key maps, path classification, endpoint parsing, and host persistence are
unit tests. The end-to-end suite starts a real agent in the same process with its synthetic screen,
pairs through the real signaling server with the host approving, connects, receives video frames,
measures a ping round trip, sends input, disconnects, and checks that an unpaired controller is
rejected and an unreachable host ends cleanly. About one second, no permissions.

## Known limits at this step

- Video shows the host's cursor baked into the stream. Local cursor rendering is Phase 2.
- Cmd+Tab and other OS-level shortcuts cannot be captured; use the toolbar.
- No rendezvous client. LAN, direct addresses, and Tailscale only.
