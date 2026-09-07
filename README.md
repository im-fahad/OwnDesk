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
                       ScreenCaptureKit + libwebrtc, input injection, headless CLI
apps/mac-controller    MacBook controller (Swift)                  [pending]
apps/android-controller Android controller (Kotlin)                [pending]
services/rendezvous    Cloud signaling relay (Node, TypeScript)    [pending]
tools/web-harness      Browser test client, development only
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
```

Run the agent and try it from a browser (see [apps/mac-agent/README.md](apps/mac-agent/README.md)):

```sh
cd apps/mac-agent && swift run prc-agent --file-identity   # terminal 1
npm run harness                                             # terminal 2, then open http://127.0.0.1:8080/
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
