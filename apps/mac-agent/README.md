# PRC Mac agent

The host side of PRC: embedded signaling endpoint, pairing, mutual session authentication,
ScreenCaptureKit into libwebrtc, and CGEvent input injection. Spec sections 4.1, 7, 8, 12 to 15, 20, 21.

Three targets:

- `PRCAgentCore`: everything, as a library.
- `prc-agent-app`: the menu bar app (spec section 19). Remote Access switch, active session with
  Disconnect, trusted devices with Revoke, a pairing window with QR code and fingerprint approval,
  permission warnings with links to System Settings, notifications when bundled.
- `prc-agent`: a headless runner that prints events and takes commands on stdin, for development,
  the browser harness, and `npm run e2e`.

## Build and run

```sh
cd apps/mac-agent
swift build
swift run prc-agent-app --file-identity      # menu bar app, development mode
swift run prc-agent --file-identity          # headless runner
```

For daily use build a real app bundle instead; see "App bundle, signing, and start at login" below.

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
| `--synthetic-screen` | **Test only.** Stream a generated 720p pattern instead of the screen. No Screen Recording needed. |

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

## App bundle and start at login

```sh
scripts/build-apps.sh              # dist/PRC Agent.app and dist/PRC Controller.app, ad-hoc signed
scripts/install-launch-agent.sh    # copies the agent to ~/Applications and starts it at login
```

No certificate, Apple account, or notarization is involved: this is personal use and the apps
never leave your machines. The one consequence of ad-hoc signing is that macOS remembers the
Screen Recording and Accessibility grants by code signature, and an ad-hoc signature changes with
every build. After you rebuild and reinstall the agent, grant both permissions again; the panel
shows a warning with a button to the right System Settings pane until you do.

If that chore ever gets old, `scripts/make-signing-identity.sh` creates a free local self-signed
identity (no Apple involvement) and `PRC_SIGN_IDENTITY="PRC Local Signing" scripts/build-apps.sh`
signs with it, after which the grants survive rebuilds. Optional.

The LaunchAgent uses `RunAtLoad` and `KeepAlive`, so the agent starts at login and restarts after a
crash (spec section 18). Once installed this way, do not also open the app from Finder: launchd
already runs it, and a second copy exits immediately. To restart it after granting a permission,
quit it from its menu bar panel and launchd brings it back, or run
`launchctl kickstart -k gui/$(id -u)/com.prc.agent`. Logs go to `~/Library/Logs/PRC`. `scripts/uninstall-launch-agent.sh`
removes it and leaves trusted devices and settings in place.

The bundled app keeps its identity backed by the Secure Enclave when available. An ad-hoc signed
build stores the enclave key's opaque representation in `~/Library/Application Support/PRC/identity.json`
(mode 0600; the blob is useless on any other device and the private key never leaves the enclave),
because a Keychain item would prompt after every rebuild. A build signed with a stable identity uses
the Keychain instead. Trusted devices and settings live in the same folder. Settings are in the
panel's Settings section and apply after a relaunch.

## Driving the menu bar app from a script

The app opens a same-user control channel: a loopback port plus a random token in
`~/Library/Application Support/PRC/control.json` (mode 0600). `prc-agent ctl` talks to it:

```sh
prc-agent ctl status                 # remote access, session, pending pairing request, permissions
prc-agent ctl pair                   # open the pairing window; prints the payload text
prc-agent ctl pending [timeout ms]   # wait for a request; prints the controller's fingerprint
prc-agent ctl approve | deny         # answer it, after comparing fingerprints
prc-agent ctl devices | revoke <prefix> | end | access on|off | cancel | quit
```

Every command is a button the panel already has; nothing here reaches the network or runs
commands. It exists so pairing and connecting can be scripted, for example from a second Mac
over SSH, which is how the two-app test in this repo was run.

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
an ad-hoc signature changes per build. `scripts/install-launch-agent.sh` clears the stale entries
with `tccutil reset` on every reinstall; by hand, remove PRC Agent from the list with the minus
button, let it ask again, grant, and restart it.

## First end-to-end test with the browser harness

1. Start the agent: `swift run prc-agent --file-identity`. Note the fingerprint it prints.
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
| `TrustStore.swift` | Trusted controllers on disk, owner-only permissions |
| `Agent.swift` | Wiring and the dev file identity store |

## Headless end-to-end test

```sh
npm run e2e                      # from the repo root, after `swift build` here
npm run e2e -- --real-screen     # capture the real screen; needs Screen Recording for your terminal
npm run e2e -- --no-media        # signaling and authentication only
npm run e2e -- --input           # also inject one harmless mouse move on this Mac
PRC_E2E_VERBOSE=1 npm run e2e    # echo the agent's output
```

[tools/e2e/run.ts](../../tools/e2e/run.ts) spawns the real `prc-agent` binary and acts as a
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

Nineteen tests. Pairing and session flows run against an in-memory transport with fake media.
The signaling server is tested over a real WebSocket on localhost. The WebRTC test runs libwebrtc on
both ends in one process, negotiates, exchanges ICE, opens all three data channels, and sends
messages both ways. No permission is needed for any of them, so they run anywhere.

## Known limits at this step

- No rendezvous client. LAN and Tailscale paths only.
- The cursor is baked into the video. Local cursor rendering is Phase 2.
- One display, the main one.
