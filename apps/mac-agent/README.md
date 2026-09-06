# PRC Mac agent

The host side of PRC: embedded signaling endpoint, pairing, mutual session authentication,
ScreenCaptureKit into libwebrtc, and CGEvent input injection. Spec sections 4.1, 7, 8, 12 to 15, 20, 21.

Two targets:

- `PRCAgentCore`: everything, as a library the menu bar app will link later.
- `prc-agent`: a headless development runner that prints events and takes commands on stdin.

## Build and run

```sh
cd apps/mac-agent
swift build
swift run prc-agent --file-identity
```

Options:

| Flag | Effect |
|---|---|
| `--name <text>` | Host name shown to controllers and advertised over Bonjour |
| `--port <n>` | Signaling port, default 47500. `0` picks an ephemeral port. |
| `--data-dir <path>` | Where trusted devices live. Default `~/Library/Application Support/PRC` |
| `--no-media` | Signaling and sessions only. Offers are answered with `SESSION_END error`. |
| `--no-input` | Validate input messages but never inject them |
| `--no-bonjour` | Do not advertise on the LAN |
| `--file-identity` | **Development only.** Keep the identity as a software key in `<data-dir>/identity.key` instead of the Keychain and Secure Enclave. |

Why `--file-identity` exists: a `swift build` binary is ad-hoc signed, and its signature changes on
every rebuild. The Keychain ties an item to the signature, so each rebuilt binary would prompt for
Keychain access. The menu bar app in a later step is signed with a persistent identity and uses the
Keychain path, which is the default when the flag is absent.

Commands while running:

```text
pair              open a 120 s pairing window, print the QR payload JSON to paste into a controller
cancel            close the pairing window
y | n             approve or deny the pending pairing request after comparing fingerprints
devices           list trusted devices
revoke <prefix>   revoke by device id prefix
access on|off     Remote Access kill switch: off ends sessions, stops listening and advertising
end               end the active session
status            permissions, remote access, session, port
quit
```

## Permissions

| Permission | Needed for | Granted to |
|---|---|---|
| Screen Recording | capture | the process that runs the binary. From Terminal, that is Terminal.app. |
| Accessibility | input injection | same |

The agent asks for both on start when they are missing and prints their state. After granting one,
restart the agent. Without Screen Recording, a controller that authenticates gets
`SESSION_REJECT host_error` and the agent prints a warning.

## First end-to-end test with the browser harness

1. Start the agent: `swift run prc-agent --file-identity`. Note the fingerprint it prints.
2. Serve the harness from the repo root: `npm run harness`, then open http://127.0.0.1:8080/ in Safari
   or Chrome. To test from another machine on the LAN, use `npm run harness -- --host 0.0.0.0` and open
   the page from that machine.
3. In the agent, type `pair`. Copy the JSON line it prints into the harness's QR payload box and click Pair.
4. The agent prints the controller's fingerprint. The harness shows its own fingerprint. If they match,
   type `y` in the agent.
5. Click Connect in the harness. Expected: `SESSION_CHALLENGE`, `SESSION_ACCEPT`, then video within a
   second or two, and the status line shows `Direct (LAN)`.
6. Move the mouse over the video and click. Type with the video focused. Send a text event.

`pair` payloads expire after 120 seconds and after one attempt.

## What is where

| File | Role |
|---|---|
| `SignalingServer.swift` | WebSocket server on Network.framework, Bonjour advertisement |
| `SessionCoordinator.swift` | Envelope verification, pairing, session state machine, timers, kill switch |
| `MediaSession.swift` | Protocol between coordinator and media, plus the live ScreenCaptureKit + WebRTC implementation |
| `ScreenCapturer.swift` | SCStream to NV12 pixel buffers, static-frame repeat |
| `WebRTCSession.swift` | Peer connection as answerer, video sender, data channels, path detection |
| `InputInjector.swift` | CGEvent posting with rate limits, click counting, drag, scroll phases, Unicode text |
| `TrustStore.swift` | Trusted controllers on disk, owner-only permissions |
| `Agent.swift` | Wiring and the dev file identity store |

## Tests

```sh
swift test
```

Nineteen tests. Pairing and session flows run against an in-memory transport with fake media.
The signaling server is tested over a real WebSocket on localhost. The WebRTC test runs libwebrtc on
both ends in one process, negotiates, exchanges ICE, opens all three data channels, and sends
messages both ways. No permission is needed for any of them, so they run anywhere.

## Known limits at this step

- No menu bar UI yet. Approval and the kill switch are stdin commands.
- No rendezvous client. LAN and Tailscale paths only.
- The cursor is baked into the video. Local cursor rendering is Phase 2.
- One display, the main one.
