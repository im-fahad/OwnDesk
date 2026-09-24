# OwnDesk Mac agent: the hosting half

The host side of OwnDesk: the signalling endpoint, pairing, mutual session authentication,
ScreenCaptureKit into libwebrtc, and CGEvent input injection. Spec sections 4.1, 7, 8, 12 to 15,
20, 21.

**This is a library, not the app you install.** `OwnDeskAgentCore` is one of the two halves inside
[`apps/owndesk`](../owndesk), which is what runs on each Mac. See [../../README.md](../../README.md) for how
the two halves fit together.

Two targets:

- `OwnDeskAgentCore`: the hosting half, as a library. Used by `apps/owndesk`.
- `owndesk-agent`: a headless runner that prints events and takes commands on stdin, for development,
  the browser harness, and `npm run e2e`.

## Build and run

```sh
cd apps/mac-agent
swift build
swift run owndesk-agent --file-identity          # headless runner
```

For daily use install the app instead: `scripts/build-apps.sh owndesk && scripts/install-owndesk.sh`.

Testing a host change without reinstalling the app: stop the installed one with
`launchctl bootout gui/$(id -u)/io.github.im-fahad.owndesk`, run
`(sleep 600 | swift run owndesk-agent --port 47500 --data-dir <a copy of the app's data> --file-identity) &`,
and restore it with `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.im-fahad.owndesk.plist`.
The `sleep` pipe matters: the CLI exits when stdin reaches EOF, which a backgrounded process hits
immediately.

Options:

| Flag | Effect |
|---|---|
| `--name <text>` | Host name shown to controllers and advertised over Bonjour |
| `--port <n>` | Signaling port, default 47500. `0` picks an ephemeral port. |
| `--data-dir <path>` | Where trusted devices live. Default `~/Library/Application Support/OwnDesk` |
| `--no-media` | Signaling and sessions only. Offers are answered with `SESSION_END error`. |
| `--no-input` | Validate input messages but never inject them |
| `--no-bonjour` | Do not advertise on the LAN |
| `--file-identity` | **Development only.** Keep the identity as a software key in `<data-dir>/identity.key` instead of the Keychain and Secure Enclave. |
| `--synthetic-screen` | **Test only.** Stream a generated 720p pattern instead of the screen. No Screen Recording needed. |

Why `--file-identity` exists: a `swift build` binary is ad-hoc signed, and its signature changes on
every rebuild. The Keychain ties an item to the signature, so each rebuilt binary would prompt for
Keychain access. Without the flag the Keychain path is used.

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

## The app

The hosting half ships inside `OwnDesk.app`. Building, installing, signing, starting at login, and
driving it from a script are in [`apps/owndesk`](../owndesk/README.md).

## Permissions

| Permission | Needed for | Granted to |
|---|---|---|
| Screen Recording | capture | the process that runs the binary. From Terminal, that is Terminal.app. |
| Accessibility | input injection | same |

The agent asks for both on start when they are missing and prints their state. After granting
Screen Recording, restart the agent. Without it, a controller that authenticates gets
`SESSION_REJECT host_error` and the agent prints a warning.

If System Settings shows the switch already on while the agent still reports the permission as
missing, the entry belongs to a previous build: macOS binds each grant to the app's signature, and
an ad-hoc signature changes per build. `scripts/install-owndesk.sh` clears the stale entries
with `tccutil reset` on every reinstall; by hand, remove the entry from the list with the minus
button, let it ask again, grant, and restart it.

## First end-to-end test with the browser harness

1. Start the agent: `swift run owndesk-agent --file-identity`. Note the fingerprint it prints.
2. Serve the harness from the repo root: `npm run harness`, then open http://127.0.0.1:8080/ in Safari
   or Chrome on this Mac.

   To test from another machine on the LAN, start it with `npm run harness -- --host 0.0.0.0`. The
   server prints this Mac's LAN URLs, for example `http://192.168.1.50:8080/`. Open one of those on
   the other machine. `0.0.0.0` is the listen address and cannot be browsed to. If the page does not
   load from the other machine, allow `node` in System Settings > Network > Firewall on this Mac.
3. In the agent, type `pair`. Copy the JSON line it prints into the harness's QR payload box and click Pair.
4. The agent prints the controller's fingerprint. The harness shows its own fingerprint. If they match,
   type `y` in the agent.
5. Click Connect in the harness. Expected: `SESSION_CHALLENGE`, `SESSION_ACCEPT`, then video within a
   second or two, and the status line shows `Direct (LAN)`.
6. Move the mouse over the video and click. Type with the video focused. Send a text event.

`pair` payloads expire after 120 seconds and after one attempt.

The harness does its signing with the pure-JavaScript noble libraries rather than WebCrypto, because
browsers disable WebCrypto on plain `http://` pages that are not localhost, and the page has to stay
plain http so it can open the agent's `ws://` endpoint.

## What is where

| File | Role |
|---|---|
| `SignalingServer.swift` | WebSocket server on Network.framework, Bonjour advertisement |
| `SessionCoordinator.swift` | Envelope verification, pairing, session state machine, timers, kill switch |
| `MediaSession.swift` | Protocol between coordinator and media, plus the live ScreenCaptureKit + WebRTC implementation |
| `ScreenCapturer.swift` | SCStream to NV12 pixel buffers, static-frame repeat |
| `WebRTCSession.swift` | Peer connection as answerer, video sender, data channels, path detection |
| `InputInjector.swift` | CGEvent posting with rate limits, click counting, drag, scroll phases, Unicode text |
| `OwnDeskPeers` (in `packages/swift`) | The peer list on disk, with a permission per direction |
| `Agent.swift` | Wiring and the dev file identity store |

## Headless end-to-end test

```sh
npm run e2e                      # from the repo root, after `swift build` here
npm run e2e -- --real-screen     # capture the real screen; needs Screen Recording for your terminal
npm run e2e -- --no-media        # signaling and authentication only
npm run e2e -- --input           # also inject one harmless mouse move on this Mac
OWNDESK_E2E_VERBOSE=1 npm run e2e    # echo the agent's output
```

[tools/e2e/run.ts](../../tools/e2e/run.ts) spawns the real `owndesk-agent` binary and acts as a
controller from Node with werift, an independent WebRTC implementation. It pairs with proof and
approval, checks the fingerprint the host shows, authenticates, verifies a stranger is rejected,
negotiates H.264 and the three data channels, checks ping and display info, sends a wrong-channel
and a forbidden message, counts video RTP, ends the session, and shuts the agent down. Sixteen
steps, about fifteen seconds, no permissions, no browser, no display.

By default the agent streams a generated pattern (`--synthetic-screen`) so video can be verified
anywhere. That flag exists only for testing and is never on unless asked for.

## Tests

```sh
swift test
```

Twenty-eight tests. Pairing and session flows run against an in-memory transport with fake media.
The signaling server is tested over a real WebSocket on localhost. The WebRTC test runs libwebrtc on
both ends in one process, negotiates, exchanges ICE, opens all three data channels, and sends
messages both ways. No permission is needed for any of them, so they run anywhere.

## Known limits at this step

- No rendezvous client. LAN and Tailscale paths only, which is the deployed answer, not a gap.
- The cursor is baked into the video. Local cursor rendering is Phase 2.
- One display, the main one.
