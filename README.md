# PRC: Personal Remote Control System

Private, self-hosted remote control for a Mac Mini from a MacBook or an Android phone.
Screen and input travel only inside an encrypted WebRTC connection. Signaling is signed
end to end by per-device keys, so neither the LAN, the rendezvous server, nor a TURN relay
can see or inject anything.

The authoritative design is [personal-remote-control-spec-v2.md](personal-remote-control-spec-v2.md).

## Layout

```text
packages/protocol      JSON Schemas, key code tables, signing test vectors,
                       TypeScript reference implementation (single source of truth)
packages/swift         Swift package used by the Mac agent and Mac controller
  PRCIdentity          P-256 keys in Secure Enclave or Keychain, signing, encodings
  PRCProtocol          Envelope signing and receiver rules, typed payloads, pairing, server auth
apps/mac-agent         Mac Mini agent (Swift): signaling server, pairing, sessions,
                       ScreenCaptureKit + libwebrtc, input injection, menu bar app, headless CLI
apps/mac-controller    MacBook controller (Swift): discovery, pairing, session with
                       reconnection, WebRTC receiver, input capture, SwiftUI app
apps/android-controller Android controller (Kotlin)                [pending]
services/rendezvous    Cloud signaling relay (Node, TypeScript)    [pending]
tools/web-harness      Browser test client, development only
tools/e2e              Headless end-to-end test driving the real agent from Node
scripts/               App bundles, signing identity, LaunchAgent install
infra/                 Docker, coturn, reverse proxy               [pending]
```

## Development

Requirements: Node 24 or newer, Xcode 26 or newer.

```sh
npm install
npm test                                   # protocol package tests
npm run typecheck

cd packages/swift && swift test            # Swift package against the same vectors
cd apps/mac-agent && swift test            # agent: flows, WebSocket server, WebRTC loopback
cd apps/mac-controller && swift test       # controller, including an in-process agent round trip with video
npm run e2e                                # headless end to end against the real agent binary
```

Real use, as apps:

```sh
scripts/build-apps.sh agent && scripts/install-launch-agent.sh        # on the Mac mini: starts at login
scripts/build-apps.sh controller && scripts/install-controller.sh     # on the MacBook: ~/Applications/PRC Controller.app
```

No certificate is needed. Both apps are ad-hoc signed.

After a rebuild, macOS asks for the agent's Screen Recording and Accessibility permissions again
(ad-hoc signatures change per build). The optional `scripts/make-signing-identity.sh` avoids that.

Two real machines: run the agent on one, then on the other
`swift run prc-controller-cli discover`, `pair`, and `connect` (see the controller README).
Measured on a Wi-Fi LAN between a Mac mini and a MacBook Pro: 1920x1080 within two seconds,
52 to 56 fps, 8 to 12 ms round trip.

Run the agent and try it from a browser (see [apps/mac-agent/README.md](apps/mac-agent/README.md)):

```sh
cd apps/mac-agent && swift run prc-agent --file-identity          # terminal 1, on the host
cd apps/mac-controller && swift run prc-controller --file-identity # terminal 2, on the MacBook
```

Or from a browser instead of the controller app (see [apps/mac-agent/README.md](apps/mac-agent/README.md)):

```sh
npm run harness                                             # then open http://127.0.0.1:8080/
npm run harness -- --host 0.0.0.0                           # instead, to open it from another machine
                                                            # at the LAN URL the server prints
```

Regenerate test vectors and generated types after changing a schema:

```sh
cd packages/protocol
npm run vectors
npm run codegen
```

## Security rules

Section 24 of the spec lists the rules every contributor, human or AI, must follow.
The short version: no exposed control ports, no custom crypto, no private keys off the
device, no command execution in the protocol, validate everything, fail closed.
