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

## Layout

An editor-style window: a header, panels that come and go, and the remote screen filling whatever is
left. Only the screen is permanent.

| Control | What it does |
|---|---|
| Sidebar button, ⌘B | Paired hosts, nearby hosts, this Mac's fingerprint, and pairing |
| Log button, ⌘J | Event log along the bottom |
| Quality menu | Resolution cap and the sharp-text or smooth-motion trade-off |
| Keys menu | Shortcuts macOS never lets a window see, plus the text sender |
| Pointer button | Pauses input without disconnecting |
| ⌘K | Connect or disconnect |

The keyboard shortcuts only reach the app when the pointer is off the video: while it is over the
stream every key belongs to the host, deliberately. `prc-controller-cli app panels [sidebar|log|text]`
reports or toggles the panels for scripted use.

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

## Choosing an address

**Connect** needs no address in the normal case. The controller opens a TCP connection to every
address the host advertised at pairing time at once and uses the first that answers, so the same
button works at home on the LAN and away over Tailscale. Bonjour is tried first when the host is on
the current network. The address field only overrides that.

If the host never answers, the attempt ends after 15 seconds rather than hanging: an agent drops
envelopes addressed to a different device id without replying (spec section 6 rule 3), so a silent
host usually means this controller is paired with a *different* Mac than the one at that address.
Each host row shows its fingerprint for exactly this reason: two entries for the same Mac are
otherwise indistinguishable, and forgetting the live one leaves a stale entry that can never connect.

The status line names the path: **Direct (LAN)** on the same network, **Direct (Tailscale)** over the
tailnet, **Direct (Internet)**, or **Relayed**. Tailscale may itself relay through a DERP server when
neither side can be reached directly, which shows up as a round trip of a few hundred milliseconds
rather than the ~10 ms of a LAN.

## Quality

The **Quality** menu in the toolbar caps the resolution the host sends: Automatic, 1080p, 720p,
540p, or 360p. It also chooses the trade-off when the link cannot carry everything:

- **Sharp text** keeps the resolution and lets the frame rate fall. Text stays readable.
- **Smooth motion** lets the picture soften to keep frames coming.

Both are sent as `stream_settings` on the control channel and reapplied on every connect. Lower
resolutions help when the link is the bottleneck, because a 1080p frame at a megabit takes a
noticeable fraction of a second to arrive. They do not help when the delay comes from the network
path itself; see below.

## When the picture is soft

`prc-controller-cli app stats` reports what is actually arriving: resolution, frame rate, kilobits
per second, and lost packets. That distinguishes the two causes.

A desktop keeps its full resolution and gives up frame rate under pressure, because text stays
readable at 10 fps and unreadable at half resolution. So a soft picture usually means the stream
really is being downscaled, which points at the declared path or the host's caps. A picture that is
sharp but choppy means the link is simply narrow.

Tailscale relays through a DERP server whenever it cannot connect the two machines directly, and a
relay can be far away and slow. One measured example: 0.92 Mbit/s with a 600 ms round trip between a
home Mac and a MacBook on mobile data. Nothing in the encoder can make full-motion video good at
that rate; still screens and text remain sharp. `tailscale status` names the relay when one is in
use, and `tailscale ping <host>` says whether a direct connection was established.

## When everything lags

`prc-controller-cli app stats` also reports `jitter_ms` and `jitter_buffer_ms`. The receiver sizes
its buffer from the jitter it sees, so an unsteady path costs delay directly: 130 ms of jitter
measured on a relay produced a 580 ms buffer, on top of the round trip. Lowering the resolution does
not help that, because the buffer is protecting against arrival timing rather than volume.

The remedy is a direct path. `tailscale netcheck` on both machines shows why one is not available.
`PortMapping` empty on the home side means the router offers no UPnP, NAT-PMP or PCP, so Tailscale
cannot open a port; enabling one of those on the router is the single biggest improvement available.
A phone or carrier network on the other side may block hole punching regardless, in which case Wi-Fi
on the controller is the practical answer.

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
