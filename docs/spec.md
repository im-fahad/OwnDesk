# Personal Remote Control System (PRC) --- Specification v2

Revision date: 2026-09-07. Amended 2026-09-10 to match what was built.
Supersedes: personal-remote-control-ai-agent-spec.md (v1)
Protocol version defined by this document: 1

The protocol in sections 5 to 17 and 21 is unchanged and is what all three implementations speak.
The amendments are to roles, deployment and UI: see section 0.1. What exists today, and the traps
found on the way, is [implementation.md](implementation.md); [../README.md](../README.md) is the
guided tour.

---

## 0. What changed from v1

v1 had the right shape. v2 keeps the architecture and fixes the places where v1 was vague, contradictory, or would not have delivered its own security goals.

| Area | v1 | v2 |
|---|---|---|
| LAN without the server | Claimed possible, no mechanism | The agent embeds its own signaling endpoint. LAN needs no cloud server at all. |
| Authentication vs. WebRTC | Challenge-response over signaling, unbound to DTLS | Every signaling message is signed by the device identity key. SDP is therefore fingerprint-bound. A compromised server cannot MITM. |
| Server authentication | None | Devices authenticate to the server with their identity key. The Mac Mini pushes its allowlist to the server. |
| Trust authority | Split between server REST API and Mac Mini | The Mac Mini is the only authority. The server holds no durable state. |
| TURN credentials | Unspecified | Time-limited credentials issued per connection from a shared secret. |
| Fallback logic | Custom 3-level state machine | ICE already prefers host, then server-reflexive, then relay. Only the signaling path is chosen manually. |
| Input protocol | Inconsistent names, "key": "A" | Full catalogue with W3C key codes, modifiers, text events, relative and absolute mouse, per-display coordinates. |
| Data channels | One implicit channel | Three channels with explicit reliability settings. |
| Video | "Video encoder" | VideoToolbox H.264 via libwebrtc, 1080p cap, balanced degradation. |
| Headless Mac Mini | Not addressed | Display, login, sleep, and signing requirements are spelled out. Sleep handling moves to MVP. |
| MacBook stack | Tauri or Swift | Native Swift. |
| Pairing | QR plus approval | QR plus proof of QR possession plus fingerprint confirmation. LAN-only by design. |
| Shared protocol | A folder | JSON Schema as the single source of truth with codegen for Swift, Kotlin, TypeScript. |
| crypto package | Contradicted rule 2 | Renamed identity. Thin wrappers over platform key stores only. |

---

## 0.1 What changed while building it

v2 described one host and two controllers. It is now symmetric between the Macs, and one product
decision by the owner removed a whole component.

| Area | v2 as written | As built |
|---|---|---|
| Roles | Mac mini hosts, MacBook controls | Either Mac does either, in one app. Hosting is a switch, off until turned on. The phone controls only. |
| Apps | `mac-agent` and `mac-controller` as separate apps | One `PRC.app` containing both halves as libraries. The old app targets are superseded. |
| Trust store | One direction, "trusted controllers" | One peer record per device with two independent permissions: may control us, we may control it. Key lookup is gated on the relevant one, so revoking a direction fails closed. |
| Internet path | Rendezvous server plus TURN on a VPS | Tailscale. Same signed protocol over a tailnet address, no server to run, no VPS to pay for. The rendezvous protocol in section 11 is still specified and still unbuilt. |
| Signing | A persistent identity from day one, ideally Developer ID | Ad-hoc, by the owner's decision: these apps are personal and never distributed. The cost is re-granting Screen Recording and Accessibility after each rebuild, which the install script handles with `tccutil reset`. |
| Android input | Trackpad first, screen view second | Both, switchable, with touch as the default: on a phone the whole desktop is visible at once, so putting the pointer where the finger lands is quicker to aim than nudging it. Pinch magnifies on the phone alone. |
| Android pairing | QR only | QR by camera, or the same code pasted as text. Decoded on the phone, offline. |
| Host UI | Menu bar only | Menu bar item plus a window: the window is needed anyway to show a screen this Mac is controlling. |
| Codec negotiation | "H.264 via VideoToolbox" | Both sides must *state* it: name H.264 as the preferred codec and offer an H.264 level the picture actually fits in, or libwebrtc silently agrees on VP8. See implementation.md. |

Sections 5 to 25 were written when only the Mac mini could host. Where they say "the Mac Mini",
read "whichever Mac is hosting this session"; the rules are the same whichever way round the two
Macs are, and the examples were left with their original names so older notes still match.

---

## 1. Project goal

A private, self-hosted remote-control system for personal use.

- Each Mac runs one app that can host, control, or both. Hosting is off until switched on.
- A Mac controls another Mac.
- An Android phone controls either Mac.
- Controllers connect from the same LAN, or across the Internet over a Tailscale tailnet.
- Low-latency screen viewing plus mouse and keyboard control.
- Secure device pairing and mandatory authentication on every session.
- Automatic connection fallback. No remote-control port is ever exposed directly to the Internet.

Personal use only. No public distribution.

---

## 2. Architecture

```text
        ┌───────────────────────────┐      ┌───────────────────────────┐
        │         Mac mini          │      │          MacBook          │
        │          PRC.app          │      │          PRC.app          │
        │  ┌─────────────────────┐  │      │  ┌─────────────────────┐  │
        │  │ hosting half        │  │◄────►│  │ controlling half    │  │
        │  │  WebSocket :47500   │  │      │  └─────────────────────┘  │
        │  │  Bonjour advert     │  │      │  ┌─────────────────────┐  │
        │  │  ScreenCaptureKit   │  │      │  │ hosting half        │  │
        │  │  CGEvent injection  │  │◄────►│  │  (same, either way) │  │
        │  └─────────────────────┘  │      │  └─────────────────────┘  │
        │  ┌─────────────────────┐  │      └───────────────────────────┘
        │  │ controlling half    │  │
        │  └─────────────────────┘  │      ┌───────────────────────────┐
        │  shared: identity key,    │      │      Android phone        │
        │  peer list, window        │◄────►│   PRC, the phone app      │
        └───────────────────────────┘      │  controlling half only    │
                                           └───────────────────────────┘

        ◄────►  signalling: signed envelopes over a WebSocket the host serves
                media: WebRTC, DTLS-SRTP, H.264 video plus three data channels
                the phone reaches either Mac exactly the same way

        LAN     the controller reaches that WebSocket directly, found by Bonjour.
                No server of any kind is involved.
        Away    the same WebSocket at a Tailscale address. Tailscale connects the
                two directly when it can and relays through DERP when it cannot.
        Later   the rendezvous server and TURN of section 11 remain specified and
                unbuilt; they would carry signalling only, and are unnecessary while
                a tailnet is available.
```

Two planes:

- **Control plane**: presence, pairing, session authentication, SDP, ICE. Carried by the host's own endpoint, reached on the LAN or over the tailnet, and by the rendezvous server if one is ever built. Every control-plane message is signed end to end. The transport is never trusted, which is what makes it safe to carry the control plane over something we do not own.
- **Data plane**: screen video and input events. Carried only inside the WebRTC connection. Never touches a server. A relay, whether TURN or Tailscale's DERP, forwards encrypted packets it cannot read.

---

## 3. Key decisions

| Decision | Choice | Reason |
|---|---|---|
| Identity key type | ECDSA P-256, SHA-256 | Supported by Secure Enclave, Android Keystore, CryptoKit, WebCrypto. Ed25519 is not hardware-backed on either platform. |
| Signature encoding | Raw r\|\|s, 64 bytes, base64url | Uniform across platforms. Android must convert from DER. |
| Public key encoding | X9.63 uncompressed, 65 bytes, base64url | Universal. |
| Device ID | Lowercase hex SHA-256 of the 65-byte public key | Self-certifying. |
| Signaling message format | JSON envelope, payload as base64url of exact JSON bytes | Avoids canonical JSON across three languages. |
| LAN signaling | WebSocket served by the agent, advertised via Bonjour | LAN works with no Internet and no server. |
| Cloud signaling | WSS to the rendezvous server | Metadata privacy. Signed envelopes carry the real security. |
| Offerer | Controller | Controller creates data channels and receives video. |
| Codec | H.264 via VideoToolbox | Hardware encode on Mac, hardware decode on Android and Mac. |
| Fallback | Single ICE negotiation with all candidate types | ICE already picks the best path. |
| MacBook stack | Native Swift | Shares code with the agent. Web views swallow system shortcuts. |
| Mac app shape | One app with both halves; hosting off by default | A Mac used only as a controller never constructs capture and is never asked for those permissions. |
| Internet path | Tailscale, not a rendezvous server | Same signed protocol, no server to run or pay for. WireGuard underneath, and it is already trusted with far more than this. |
| Android pointer | Absolute touch by default, relative trackpad on request | The whole desktop is visible on a phone, so landing the pointer under the finger aims faster; the trackpad is there for small targets. |
| Android magnification | Local only, never asked of the host | Costs no bandwidth and keeps working on a poor link. |
| Code signing | Ad-hoc, no certificate | The owner's decision: personal use, never distributed. Grants are re-issued after a rebuild by the install script. |
| Pairing | LAN only, physical approval on the host | Removes remote pairing attack surface. |
| Concurrency | One active controller. Second request is rejected as busy. | Simplest safe MVP behavior. |
| Host runtime | LaunchAgent in the login session, KeepAlive | Restarts after crash and after login. |

---

## 4. Components

### 4.1 The hosting half

Lives inside `PRC.app` and is constructed only when hosting is switched on. Runs in the user's
login session under a LaunchAgent, so it comes back after login and after a crash, but not after
the owner chooses Quit.

Responsibilities:

- Own the device identity key in the Secure Enclave.
- Serve the signalling endpoint on port 47500 and advertise `_prc._tcp` over Bonjour.
- Run pairing with local approval and a fingerprint comparison.
- Authenticate every session with challenge-response and verify every signed envelope.
- Capture the screen with ScreenCaptureKit and feed libwebrtc, naming H.264 as the preferred codec.
- Receive input on data channels, validate it, and inject it with CGEvent.
- Hold a power assertion while a session is active.
- Show the active session and let the owner end it.
- Never execute arbitrary remote commands.

Required macOS permissions: Screen Recording and Accessibility, asked for when hosting is first
switched on. See section 18.

### 4.2 The controlling half

The same app, always available, needing no macOS permission at all.

Responsibilities:

- Find a host by Bonjour on this network, and otherwise probe every address it knows at once,
  taking the first that answers and remembering it.
- Authenticate, and verify the host's signatures.
- Create the three data channels and the offer. Render the video track. Map pointer position over
  the video to normalised host coordinates, letterboxing included.
- Send absolute mouse moves, buttons, precise scroll, key events, and text.
- Capture as many system shortcuts as macOS allows while the pointer is over the video, with
  toolbar buttons for the ones it cannot: Cmd+Tab, Cmd+Space, Cmd+Q.
- Show the connection state and which path it took: Direct (LAN), Direct (Tailscale),
  Direct (Internet), or Relayed.
- Reconnect automatically, and never fall back to re-pairing.

### 4.3 Android controller

Kotlin, plain Android Views, the WebRTC Android library. Controls only; it never hosts.

Responsibilities:

- Keep its identity in the Android Keystore, non-exportable.
- Pair by scanning the host's QR with the camera, or from the same code pasted as text. Decoding
  happens on the phone: a pairing code is a secret and is not sent anywhere to be read.
- Authenticate, verify the host's signatures, and apply the same receiver rules as the Macs.
- Offer the connection, render the video in a `SurfaceViewRenderer` sized to the frame's shape, and
  ask its own decoder what H.264 level it supports rather than guessing.
- Touch mode: the pointer goes where the finger lands. Trackpad mode: relative nudges, as on a
  laptop. Both send the same message types.
- Gestures as the established remote desktop apps define them: tap, double tap, tap-tap-hold to
  drag, long press and two-finger tap for right click, three-finger tap for middle, two-finger
  drag to scroll, pinch to magnify locally.
- Soft keyboard sending text events, and key events for non-printing keys.
- Show what the connection is doing, read from the WebRTC stats rather than estimated.

### 4.4 Rendezvous server — specified, not built

Node.js, TypeScript, one WebSocket endpoint, one health endpoint, behind a TLS reverse proxy.
Deferred: a tailnet does the same job with nothing to run. Section 11 defines the protocol should it
ever be wanted.

Would:

- Authenticate connecting devices by identity key against an allowlist pushed by the host.
- Track presence, relay opaque signed envelopes, issue time-limited TURN credentials.

Would not: store anything durable, inspect the inner envelopes, carry video or input, or offer any
REST API for device management.

### 4.5 TURN — specified, not built

coturn with time-limited credentials (`use-auth-secret`), treated as an untrusted packet relay.
Tailscale's own DERP relay fills this role today.

---

## 5. Identity and cryptography

No custom cryptography. Only these primitives via platform libraries:

- ECDSA P-256 with SHA-256 for identity signatures.
- HMAC-SHA256 for the pairing proof and TURN credentials.
- DTLS-SRTP inside WebRTC.
- TLS for the cloud signaling connection.

### 5.1 Device identity

Every device generates one P-256 key pair at first launch.

| Platform | Storage |
|---|---|
| macOS | CryptoKit `SecureEnclave.P256.Signing.PrivateKey`, falling back to a Keychain-stored key on Macs without Secure Enclave. |
| Android | Android Keystore EC P-256, `setIsStrongBoxBacked(true)` when available, otherwise TEE. Signatures come back DER-encoded and must be converted to raw r\|\|s. |

Private keys never leave the device. They are never sent to the server, never included in QR codes, never logged.

### 5.2 Encodings

```text
public_key  = base64url( X9.63 uncompressed point, 65 bytes, 0x04 || X || Y )
device_id   = lowercase hex( SHA-256( the 65 public key bytes ) )        # 64 chars
fingerprint = first 12 hex chars of device_id, shown as XXXX-XXXX-XXXX   # for humans
signature   = base64url( r || s ), 64 bytes
```

### 5.3 Domain separation

Every signed byte string begins with a fixed context label so a signature for one purpose can never be replayed as another.

```text
prc-signaling-v1     signaling envelopes (section 6)
prc-server-auth-v1   authentication to the rendezvous server (section 11)
prc-pairing-v1       pairing proof (section 7)
```

---

## 6. Signaling envelope

Every control-plane message between two devices, whether sent over the LAN endpoint or relayed by the server, uses this envelope.

```json
{
  "v": 1,
  "type": "SESSION_REQUEST",
  "from": "<device_id of sender>",
  "to": "<device_id of recipient>",
  "session": "<session_id or empty string>",
  "seq": 7,
  "ts": 1757203200123,
  "payload": "<base64url of the UTF-8 JSON bytes of the payload object>",
  "sig": "<base64url signature>"
}
```

Signing input, joined with `\n`, all numbers as decimal strings:

```text
prc-signaling-v1
v
type
from
to
session
seq
ts
payload
```

Receiver rules, applied in this order, all failures fatal for that message:

1. Total size at most 64 KB.
2. `v` is a supported version.
3. `to` equals the receiver's device_id.
4. `from` is a known device. For `PAIR_REQUEST` only, the key inside the payload is used and the message is self-certifying.
5. `sig` verifies against the sender's known public key.
6. `ts` is within 300 seconds of local time.
7. `seq` is greater than the last accepted `seq` from this sender for this session. `seq` starts at 1 per session and per attempt in the empty namespace. An attempt is one exchange: `PAIR_REQUEST` answered by `PAIR_RESULT`, or `SESSION_REQUEST` answered by `SESSION_CHALLENGE` or `SESSION_REJECT`. Both sides reset their `seq` state for the empty namespace once that reply is sent or received, so a retry starts at 1 again.
8. Only then is `payload` decoded and validated against the schema for `type`.

Why the payload is opaque bytes: signing the exact bytes the sender serialized removes any need for canonical JSON across Swift, Kotlin, and TypeScript.

Why this solves the MITM problem: `SDP_OFFER` and `SDP_ANSWER` carry the DTLS fingerprint inside the SDP. The SDP is inside the signed payload. libwebrtc then verifies the remote DTLS certificate against that fingerprint during the handshake. A server that swaps fingerprints breaks the signature and the session is refused.

---

## 7. Pairing

Pairing is LAN-only and requires approval on the Mac Mini. The first controller needs physical access to the Mac Mini, meaning a display or a LAN SSH session to the agent's local CLI. Every later controller can be approved through an existing remote session, because the approving UI is on the Mac Mini's screen, which the existing controller already sees.

### 7.1 Flow

```text
Mac Mini                                  New controller
--------                                  --------------
Pair New Device
  generate pairing_session_id (128-bit)
  generate pairing_code (128-bit)
  build QR payload, show QR + text
  start 120 s timer
                                          scan QR or paste text
                                          verify host_key_hash against
                                            the host's public key fetched
                                            from the local endpoint
                                          send PAIR_REQUEST (self-signed)
verify proof with pairing_code
verify envelope signature with the
  public key inside the payload
show: device name, device type,
      controller fingerprint
                                          show: own fingerprint,
                                                host fingerprint
user compares fingerprints and
clicks Approve on the Mac Mini
store controller key + name
send PAIR_RESULT (signed by host)
push TRUST_SYNC to rendezvous server
                                          verify host signature
                                          store host key, name,
                                            rendezvous URL
```

### 7.2 QR payload

```json
{
  "v": 1,
  "kind": "prc-pair",
  "host_device_id": "<device_id>",
  "host_key_hash": "<device_id, repeated for clarity>",
  "host_name": "Mac Mini M4",
  "addresses": ["192.168.1.20:47500", "[fe80::1%en0]:47500"],
  "rendezvous_url": "wss://prc.example.com/ws",
  "pairing_session_id": "<base64url 16 bytes>",
  "pairing_code": "<base64url 16 bytes>",
  "expires_at": 1757203320000
}
```

Contains no private keys, no permanent secrets, no passwords. The pairing code is single-use and dies after 120 seconds or one attempt.

### 7.3 PAIR_REQUEST payload

```json
{
  "public_key": "<base64url 65 bytes>",
  "device_name": "My MacBook",
  "device_type": "mac" ,
  "pairing_session_id": "<from QR>",
  "proof": "<base64url HMAC-SHA256>"
}
```

```text
proof = HMAC-SHA256( key = pairing_code bytes,
                     msg = "prc-pairing-v1\n" + pairing_session_id + "\n" + controller_device_id )
```

The proof stops anyone on the LAN who has not seen the QR from triggering approval dialogs. The fingerprint comparison stops anyone who has seen the QR from substituting their own key. The host key hash in the QR stops a fake host on the LAN from collecting the controller's request.

### 7.4 PAIR_RESULT payload

```json
{
  "approved": true,
  "reason": null,
  "host_public_key": "<base64url 65 bytes>",
  "host_name": "Mac Mini M4",
  "rendezvous_url": "wss://prc.example.com/ws"
}
```

Rejection reasons: `denied`, `expired`, `bad_proof`, `busy`.

### 7.5 Limits

- One pairing session open at a time.
- Three failed proofs cancel the pairing session.
- The local CLI can print the pairing text and approve a fingerprint for headless setups over LAN SSH. It is a local command, not a remote protocol.

---

## 8. Session establishment and authentication

Mutual authentication. Both sides prove possession of their identity key over a fresh transcript before any SDP is exchanged.

```text
Controller                                 Host
----------                                 ----
SESSION_REQUEST
  client_nonce, versions, capabilities
                                           check remote access enabled
                                           check controller trusted
                                           check not busy
                                           pick protocol version
                                           SESSION_CHALLENGE
                                             host_nonce, client_nonce,
                                             session_id, expires_at
SESSION_AUTH
  client_nonce, host_nonce
  (envelope signed, session = session_id)
                                           verify signature and nonces
                                           SESSION_ACCEPT
                                             client_nonce, host_nonce,
                                             display_info
                                           (envelope signed)
verify host signature and nonces
SDP_OFFER  -->
           <-- SDP_ANSWER
ICE_CANDIDATE <--> (trickle)
DTLS handshake, fingerprint checked against signed SDP
data channels open
```

### 8.1 Payloads

`SESSION_REQUEST`

```json
{
  "client_nonce": "<base64url 16 bytes>",
  "versions": [1],
  "path": "lan",
  "capabilities": { "codecs": ["H264"], "max_height": 1080, "max_fps": 60 }
}
```

`SESSION_CHALLENGE`

```json
{
  "host_nonce": "<base64url 16 bytes>",
  "client_nonce": "<echoed>",
  "session_id": "<base64url 16 bytes>",
  "version": 1,
  "expires_at": 1757246400000
}
```

`SESSION_AUTH`

```json
{ "client_nonce": "<echoed>", "host_nonce": "<echoed>" }
```

`SESSION_ACCEPT`

```json
{
  "client_nonce": "<echoed>",
  "host_nonce": "<echoed>",
  "display": { "display_id": "main", "width_px": 1920, "height_px": 1080, "scale": 2.0 },
  "resume_window_s": 600
}
```

`SESSION_REJECT`

```json
{ "reason": "remote_access_disabled" }
```

Reasons: `untrusted`, `revoked`, `remote_access_disabled`, `busy`, `auth_failed`, `version_unsupported`, `expired`, `malformed`, `host_error`. The last one means the device was accepted but the host could not start capture or media, typically because Screen Recording is not granted.

`SDP_OFFER`

```json
{ "sdp": "v=0...", "ice_restart": false }
```

`SDP_ANSWER`

```json
{ "sdp": "v=0..." }
```

`ICE_CANDIDATE`

```json
{ "candidate": "candidate:...", "sdp_mid": "0", "sdp_mline_index": 0 }
```

`SESSION_RESUME` has an empty payload `{}`. The envelope carries the session_id and is signed. The host accepts if the session exists, has not expired, was last active within the resume window, and the device is still trusted. Otherwise it replies `SESSION_REJECT` with `expired` and the controller starts over with `SESSION_REQUEST`.

`SESSION_END`

```json
{ "reason": "user" }
```

Reasons: `user`, `idle_timeout`, `revoked`, `remote_access_disabled`, `replaced`, `expired`, `error`.

### 8.2 Session lifetime

- Session expires 12 hours after `SESSION_CHALLENGE`. Full re-authentication after that.
- Resume window: 600 seconds after the last successful signaling or data-channel activity.
- Idle timeout: 120 minutes without input, configurable, sends `SESSION_END` with `idle_timeout`.
- There are no bearer tokens. The session_id is a correlation handle, not a credential. Every message is still signed.

### 8.3 Fail closed

Any failure at any step closes the signaling connection and the peer connection. Unauthenticated `SESSION_REQUEST` from an unknown device_id gets one `SESSION_REJECT` with `untrusted` and is then rate limited to one response per minute per device_id.

---

## 9. Connection paths

Only the **signaling path** is chosen explicitly. The **media path** is chosen by ICE.

### 9.1 Signaling path selection

```text
1. Resolve the host by device_id over Bonjour for up to 2 s.
2. If found: open WS to the advertised address and port.  path = "lan"
3. Else: open a TCP connection to every address stored for that host at once and use the
   first that answers. A private LAN address is "lan"; anything else, a tailnet address
   included, is "cloud".
4. If the LAN signaling drops mid-session, retry LAN once, then the stored addresses.
```

As built there is no step for the rendezvous server, and the addresses are probed in parallel
rather than in turn: trying them one after another means waiting out a timeout on the wrong network
before the right one is attempted at all. A tailnet address must declare `cloud` even though it is
private, because the overlay may be relaying it, and a host that seeds a LAN bitrate on a relayed
link produces a soft picture that looks like an encoder fault.

### 9.2 ICE servers by path

| Path | ICE servers | Result |
|---|---|---|
| lan | none | Host candidates only. Works with no Internet. |
| cloud | STUN plus TURN with time-limited credentials from the server | Direct if NAT allows, relay otherwise. ICE prefers host, then server-reflexive, then relay on its own. |

No unnecessary TURN usage: relay candidates lose to direct ones during connectivity checks, and the controller shows the selected path from `getStats`.

### 9.3 Connection type reporting

From the selected candidate pair:

| Local type | Remote type | Shown as |
|---|---|---|
| host | host | Direct (LAN) |
| srflx or prflx | any non-relay | Direct (Internet) |
| relay | any | Relayed |

A peer on the same LAN can show up as peer-reflexive when its candidate is learned from a connectivity check before its trickled candidate arrives, and libwebrtc reports no address for such a remote candidate. So a pair selected through one of our own host candidates on a private address is also reported as Direct (LAN). Addresses in Tailscale's ranges, IPv4 100.64.0.0/10 and IPv6 fd7a:115c:a1e0::/48, are reported as Direct (Tailscale) instead: they are private, but the overlay may be relaying them through a DERP server, which shows up as a round trip of several hundred milliseconds.

### 9.4 Chosen: a private overlay network instead of the rendezvous server

This is what is deployed. The three devices join a Tailscale tailnet on the free plan. The agent's embedded endpoint is then reachable over the tailnet from anywhere, so controllers use the `lan` signaling path against the stored tailnet address, ICE gathers host candidates on the tailnet interface, and Tailscale's own relays replace TURN. No rendezvous server, TURN, VPS, or domain is needed. Signed envelopes still protect against the overlay operator exactly as they protect against the rendezvous server. The apps do not change: the controller keeps a list of known host addresses to try after Bonjour fails, and the rendezvous path remains available for later.

---

## 10. Connection state machine and reconnection

```text
IDLE
 |
 v
DISCOVERING ------ LAN found ------> SIGNALING_LAN
 |                                       |
 | not found / failed                    |
 v                                       |
SIGNALING_CLOUD                          |
 |                                       |
 +----------------+----------------------+
                  v
            AUTHENTICATING     (SESSION_REQUEST .. SESSION_ACCEPT)
                  |
                  v
            NEGOTIATING        (SDP, ICE, DTLS)
                  |
                  v
            CONNECTED          (direct_lan | direct_internet | relayed)
                  |
                  | peer connection disconnected or network change
                  v
            RECONNECTING
              1. ICE restart on the existing peer connection (5 s)
              2. Re-open signaling, SESSION_RESUME, new offer with ice_restart
              3. If resume rejected: back to DISCOVERING and full auth
                  |
                  v
            CONNECTED  or  IDLE (after 60 s of failed attempts)
```

Rules:

- Reconnection never bypasses signature verification. Resume is signed like everything else.
- Network change detection uses NWPathMonitor on Apple platforms and ConnectivityManager on Android and triggers step 1 immediately.
- The user never chooses STUN or TURN.
- The user never re-pairs because of an IP change.

---

## 11. Rendezvous server protocol — specified, not built

Nothing in this section is implemented. It is kept because it is the answer if a tailnet ever stops
being acceptable, and because the device envelopes it carries are the same ones in use today.

Server-level frames are JSON with a `kind` field. They are distinct from the device envelopes they carry.

### 11.1 Connection authentication

```text
Client                         Server
------                         ------
open WSS
                               {"kind":"auth_challenge","nonce":"<base64url 32 bytes>","origin":"prc.example.com"}
{"kind":"auth",
 "device_id":"...",
 "public_key":"...",
 "role":"host" | "controller",
 "sig": sign("prc-server-auth-v1\n" + nonce + "\n" + origin + "\n" + device_id)}
                               verify device_id == SHA-256(public_key)
                               verify signature
                               host: public_key must equal HOST_PUBLIC_KEY from config
                               controller: device_id must be in the allowlist pushed by the host
                               {"kind":"auth_ok","ice_servers":[...]}   or close with code 4401
```

`ice_servers` contains the STUN URI and TURN URIs with credentials valid for 2 hours:

```text
username = "<unix expiry seconds>:<device_id>"
password = base64( HMAC-SHA1( TURN_SECRET, username ) )
```

This is coturn's `use-auth-secret` scheme. A stolen credential dies within 2 hours. Clients request fresh credentials by reconnecting.

### 11.2 Frames after authentication

| Kind | Direction | Payload | Purpose |
|---|---|---|---|
| `trust_sync` | host to server | `{ "controllers": [ { "device_id", "public_key", "name" } ] }` | Replaces the in-memory allowlist. Sent on every host connect and after every pair or revoke. Connected controllers no longer on the list are closed with 4403. |
| `presence` | server to client | `{ "device_id", "online": true }` | Host gets presence for controllers. Controllers get presence for the host. |
| `relay` | both | `{ "to": "<device_id>", "envelope": { ...section 6 envelope... } }` | Server checks `envelope.from` equals the authenticated device_id and `envelope.to` equals `to`. Forwards if online, otherwise replies `error` with `peer_offline`. |
| `error` | server to client | `{ "code", "message" }` | Non-fatal errors. |
| `ping` / `pong` | both | `{}` | Keepalive every 25 s. |

### 11.3 Server limits

- Message size at most 64 KB.
- 30 frames per second per connection, then close with 4429.
- Controllers may only relay to the host. The host may relay to any allowlisted controller.
- Nonces are single-use and expire in 60 seconds.
- Nothing is written to disk except structured logs without payloads.

### 11.4 Configuration

```text
HOST_PUBLIC_KEY   base64url 65-byte key of the Mac Mini
TURN_SECRET       shared with coturn static-auth-secret
TURN_URIS         turn:prc.example.com:3478?transport=udp, turns:prc.example.com:5349
STUN_URI          stun:prc.example.com:3478
ORIGIN            prc.example.com
```

If the server is compromised, the attacker learns which devices are online and when, can refuse to relay, and can add fake controllers to the server's allowlist. The fake controllers still fail the Mac Mini's own authentication. The attacker cannot see or inject video or input.

---

## 12. WebRTC configuration

### 12.1 Peer connection

- Controller is the offerer. Bundle policy max-bundle, RTCP mux.
- One video transceiver: controller `recvonly`, host `sendonly`.
- No audio in MVP.
- Trickle ICE.
- iceTransportPolicy `all`.

### 12.2 Data channels

Created by the controller before the offer. Host accepts by label and rejects unknown labels.

| Label | Ordered | Reliability | Carries |
|---|---|---|---|
| `input-lossy` | false | `maxRetransmits: 0` | `mouse_move`, `mouse_move_rel` |
| `input-reliable` | true | reliable | `mouse_down`, `mouse_up`, `scroll`, `key_down`, `key_up`, `text` |
| `control` | true | reliable | `hello`, `display_info`, `stream_settings`, `ping`, `pong`, `bye` |

Sender coalesces mouse moves to at most one per 4 ms. Scroll deltas are accumulated between sends on the sender side so a burst is a few messages, not hundreds.

---

## 13. Data channel protocol

JSON, UTF-8, one message per data channel frame, at most 4 KB. A binary encoding is a Phase 2 optimization, not an MVP need.

Every message:

```json
{ "v": 1, "type": "mouse_move", "ts": 12345, "...": "..." }
```

`ts` is milliseconds since the session's data channels opened, monotonic, used for latency statistics only.

### 13.1 Controller to host: input

| type | Fields | Notes |
|---|---|---|
| `mouse_move` | `display_id` string, `x` 0..1, `y` 0..1 | Absolute, normalized to the streamed display. Used by the MacBook and Android screen mode. The host must ignore one whose `ts` is older than the newest already applied: this channel is unordered with no retransmits, so on a relayed link a reordered pair would otherwise snap the cursor back to a stale position, which reads as shaking. Relative moves need no such rule, being additive. |
| `mouse_move_rel` | `dx`, `dy` in host points | Relative. Used by Android trackpad mode. Host applies its own acceleration curve. |
| `mouse_down` | `button`: `left`, `right`, `middle` | Host computes click count from timing and position and sets `mouseEventClickState`. |
| `mouse_up` | `button` | |
| `scroll` | `dx`, `dy` in points, `precise` bool, `phase`: `began`, `changed`, `ended`, `momentum`, or omitted | Precise true for trackpad and touch, false for wheel notches. Sign follows the browser WheelEvent: positive `dy` scrolls the content down. |
| `key_down` | `code` string, `modifiers` array, `repeat` bool | `code` uses W3C UI Events `KeyboardEvent.code` names such as `KeyA`, `ShiftLeft`, `MetaLeft`, `Enter`, `ArrowUp`, `F5`. Host maps to macOS virtual key codes. |
| `key_up` | `code`, `modifiers` | |
| `text` | `text` string, at most 256 code points | Inserted with `keyboardSetUnicodeString`. Used for soft keyboards, IME output, and pasted text. Never logged. |

`modifiers` values: `shift`, `control`, `alt`, `meta`, `capslock`. The host also tracks modifier state from its own key events and uses the union.

### 13.2 Control channel

| type | Direction | Fields | Notes |
|---|---|---|---|
| `hello` | both | `versions`, `app`, `app_version` | First message on `control`. Version mismatch closes the session with `bye`. |
| `display_info` | host to controller | `display_id`, `width_px`, `height_px`, `scale` | Sent on open and whenever the streamed display changes. Controllers must handle a change mid-session. |
| `capture_state` | host to controller | `state`: `active`, `paused_locked`, `paused_display_asleep`, `paused_error`; optional `detail` | Whether the host is really capturing. Sent when the control channel opens and on every change. Without it a paused capture is indistinguishable from a motionless desktop, because the last frame keeps being re-sent. |
| `stream_settings` | controller to host | `max_height`, `max_fps`, `prefer`: `latency` or `quality` | Hints. Host clamps to its own limits. `max_height` becomes a `scaleResolutionDownBy` divisor and never upscales; a missing field restores automatic behaviour. `prefer: quality` keeps the resolution and spends frames, `latency` does the reverse. Sent again on every connect, since a new session starts at the host's defaults. |
| `ping` / `pong` | both | `nonce` | Every 5 s. Three missed pongs trigger RECONNECTING. |
| `bye` | both | `reason` | Same reasons as `SESSION_END`. |

### 13.3 Messages that must never exist

```text
execute_shell   execute_command   run_script   open_terminal   eval   file_read   file_write
```

Keyboard control already lets the owner do anything a logged-in user can. That is the intended trust level for a paired device. This rule is about attack surface and input validation, not about restricting the owner. A protocol with six well-defined event types is auditable. One with a command string is not.

---

## 14. Host input injection

- Use Quartz Event Services, gated by the Accessibility permission checked with `AXIsProcessTrustedWithOptions`.
- Mouse: `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)` posted to `.cghidEventTap`. Convert normalized coordinates to global points using the streamed display's bounds. Clamp to that display.
- Drag: after `mouse_down`, subsequent moves post as `leftMouseDragged` or the equivalent for the held button until `mouse_up`.
- Double and triple click: track time since last click of the same button within 500 ms and 5 points and set `mouseEventClickState` accordingly.
- Scroll: `CGEvent(scrollWheelEvent2Source:units:wheelCount:wheel1:wheel2:wheel3:)` with `.pixel` for precise and `.line` for wheel. Set the scroll phase fields when `phase` is present so momentum scrolling behaves.
- Keyboard: `CGEvent(keyboardEventSource:virtualKey:keyDown:)` with `flags` built from the modifier set. Keep a table from W3C code to macOS virtual key code in the protocol package.
- Text: `keyboardSetUnicodeString` on a key-down and key-up pair.
- Known limits, stated in the UI: the agent cannot type at the login window, the FileVault prompt, or in some Secure Input contexts. The lock screen after login works because the agent is still running in the session.

---

## 15. Screen capture and encoding

```text
ScreenCaptureKit SCStream
  configuration:
    display: the streamed display (main display in MVP)
    width/height: scaled so the longest edge is at most 1920 (LAN may allow native in Phase 2)
    pixelFormat: 420YpCbCr8BiPlanarVideoRange (NV12)
    minimumFrameInterval: 1/60 s
    showsCursor: true (MVP), false when local cursor rendering ships in Phase 2
    queueDepth: 3
      |
      v
CMSampleBuffer -> CVPixelBuffer -> RTCCVPixelBuffer -> RTCVideoFrame
      |
      v
RTCVideoSource (capturer path) -> libwebrtc -> RTCDefaultVideoEncoderFactory
      |                                            H.264 via VideoToolbox
      v
RTP/SRTP -> controller
```

Encoder settings:

- Codec H.264, Constrained Baseline or Main, whichever the controller offers first. Do not offer VP8 or VP9. Software encoding at 1080p60 will not hold on the host and burns battery on the controller.
- `RTCRtpEncodingParameters.maxBitrateBps`: 20 Mbps on the LAN path, 8 Mbps on the cloud path.
- `maxFramerate`: 60.
- `degradationPreference`: `maintainResolution`. A desktop is mostly text, and text survives a low frame rate far better than a low resolution. An idle screen also sends almost nothing, which starves the bandwidth estimate; under `balanced` the encoder answers that by shrinking the picture, so a still desktop ends up permanently soft while using a few kbps. Measured over a relayed link: `balanced` settled at 960x540, `maintainResolution` at 1920x1080.
- A minimum bitrate under the estimate (1 Mbps on the LAN path, 600 kbps on the cloud path), so quality decisions are not made from the near-zero traffic of a still screen.
- Keyframe on request only. libwebrtc handles PLI and FIR.

Static screens: ScreenCaptureKit delivers complete frames only on change. Re-submit the last frame at 2 fps so the encoder keeps a steady cadence and freshly connected decoders converge quickly.

Capture that stops, and comes back: ScreenCaptureKit stops the stream on display sleep, screen lock and display reconfiguration, and never restarts it. Nothing downstream notices — the encoder is simply no longer fed — so the session stays healthy while the picture is frozen, and input keeps working over a dead image. The host therefore:

- treats `didStopWithError`, a sample buffer with status `stopped`, and a stall as the same event, and retries `startCapture` until it both succeeds **and** delivers a frame. Starting is not enough: at the lock screen ScreenCaptureKit opens a stream that never produces anything.
- distinguishes a dead capture from a still desktop with two signals, never one. Sample buffers of *any* status prove the stream is alive, so silence is measured from the last buffer rather than the last usable frame; and silence only counts as death when the window server agrees the screen is locked or the display is asleep. On one signal alone an idle Mac would restart its own capture every few seconds.
- retries eagerly for the first five seconds, then backs off to 2 s and 5 s, and cuts the wait short on wake and unlock. A locked Mac may sit there all night.
- bounds the static-screen repeat. Re-sending the last frame for ever is what turns a dead capture into a frozen picture that both ends report as healthy: frames keep arriving, so the controller's own freeze counters never move.
- says which it is on the control channel with `capture_state`, and re-sends `display_info` when capture comes back, because the display may have been reconfigured meanwhile.

Retina: capture at the scaled size above, not native pixels. Send `scale` in `display_info` so controllers can map coordinates exactly.

---

## 16. Bandwidth adaptation

Do not build a custom statistics loop for the MVP. libwebrtc already runs transport-wide congestion control and will reduce resolution and framerate under the `balanced` degradation preference within the caps above.

Expected results:

| Conditions | Approximate result |
|---|---|
| LAN | 1080p at 60 fps |
| Good Internet | 1080p at 30 fps |
| Average Internet | 720p at 30 fps |
| Poor Internet | 720p at 15 fps |

The path in `SESSION_REQUEST` is what the host sizes all of this from, so the controller must declare the path it is actually using. An overlay address such as Tailscale's is private but may be relayed halfway around the world: declaring `lan` there seeds a bitrate the link cannot carry, and the encoder collapses.

The controller may send `stream_settings` to lower the caps, for instance on a metered mobile connection. Phase 2 can add an explicit quality policy on top of the stats API if the defaults prove insufficient.

The bandwidth estimator starts near zero and ramps slowly, which measured as thirty seconds at 640x360 on a LAN. The host therefore seeds the estimate from the path the controller declared in `SESSION_REQUEST`: 6 Mbps start with a 20 Mbps cap on the `lan` path, 1.5 Mbps start with an 8 Mbps cap on the `cloud` path. With the seed a LAN session reaches 1920x1080 within about two seconds.

---

## 17. LAN discovery

Bonjour service type `_prc._tcp`, default port 47500, advertised only while Remote Access is on.

TXT record:

```text
id=<device_id>
name=Mac Mini M4
proto=1
```

No secrets in the TXT record. The controller matches `id` against its paired hosts and ignores unknown ones. The advertised port serves the embedded signaling WebSocket. The signaling transport is plain WS on the LAN because every message is signed and contains no secrets. TLS can be added later without protocol changes.

---

## 18. Host power, display, login, and signing

These are the operational facts that decide whether the Mac Mini is reachable when you need it.

- **Display**: ScreenCaptureKit requires an attached display. A headless Mac Mini needs an HDMI dummy plug or a virtual display. Without one there is nothing to capture.
- **Login session**: the agent runs as a LaunchAgent inside the logged-in user's session. It is not running at the login window. After a reboot you cannot log in remotely unless automatic login is enabled. Automatic login is incompatible with FileVault. Decide one way; see section 31.
- **Sleep**: enable "Prevent automatic sleeping when the display is off" and "Wake for network access" in System Settings. The agent additionally holds `kIOPMAssertionTypePreventUserIdleSystemSleep` while a session is active. Enable "Start up automatically after a power failure".
- **Signing**: macOS ties the Screen Recording and Accessibility grants to the app's code-signing identity, and an ad-hoc signature changes every build, so the grants vanish on each reinstall. The owner chose ad-hoc signing and no certificate: these apps are personal and are never distributed. `scripts/install-prc.sh` therefore clears the stale entry with `tccutil reset` on every install, and the app shows a warning with a link to the right System Settings pane until both are granted again. `scripts/make-signing-identity.sh` creates a free self-signed identity that would end the chore, and is not used. Notarization would only matter if the app were distributed.
- **LaunchAgent**: `RunAtLoad` true and `KeepAlive` set to `SuccessfulExit: false`, so the app comes back after login and after a crash but stays gone when the owner chooses Quit. `scripts/install-prc.sh` installs it as `com.prc.app`.

---

## 19. Host UI

A menu bar item, plus a window on demand. The window is needed anyway to show a screen this Mac is
controlling, so the same app draws both directions.

The menu bar panel, which is all a Mac used only as a host ever needs:

```text
Mac mini M4
fingerprint 25AA-F3B7-4F82

Let other Macs control this one          [ ON ]

Incoming
  My MacBook   Direct (LAN)            [Disconnect]

[Open PRC…]                                        [Quit]
```

The window, when controlling:

```text
┌──────────────────────────────────────────────────────────────┐
│ ●●●  PRC   Mac mini M4 · Direct (LAN)   [Quality] [Keys] [⏸] │  header, doubles as the title bar
├──────────────┬───────────────────────────────────────────────┤
│ THIS MAC     │                                               │
│  Let others  │                                               │
│  control it  │            the other Mac's screen             │
│              │                                               │
│ MACS YOU CAN │                                               │
│ CONTROL      │                                               │
│  ● MacBook   │                                               │
│              │                                               │
│ MACS THAT CAN│                                               │
│ CONTROL THIS │                                               │
│  ● MacBook   │                                               │
│              │                                               │
│ NEARBY, NOT  │                                               │
│ PAIRED       │                                               │
│              │                                               │
│ [Pair a Mac…]│                                               │
├──────────────┴───────────────────────────────────────────────┤
│ LOG                                                          │  optional, ⌘J
└──────────────────────────────────────────────────────────────┘
```

Rules the window follows, each of which cost something to learn (see implementation.md):

- The Dock icon appears while a window is open and goes away when it closes, so a Mac started at
  login adds nothing to the Dock, and an open window can still take keyboard focus.
- Closing the window hides it rather than destroying it, and Quit really quits.
- A session this Mac is hosting is always visible: the menu bar panel names the controller and
  offers Disconnect, and the header says so while the window is open.

A system notification fires when a session starts and ends. The owner must always be able to see
that someone is connected.

---

## 20. Trusted devices, revocation, kill switch

- The peer store lives in Application Support on each device: one record per peer holding
  device_id, public key, name, type, paired date, last seen, known addresses, and **two independent
  permissions** — may control us, and we may control it. No secrets, so no protection beyond file
  permissions.
- Key lookup is gated on the permission for the direction being checked, so withdrawing one makes
  verification fail closed rather than relying on a check at the call site. A peer allowed neither
  is dropped.
- Pairing sets both directions between two Macs. That costs nothing in trust: one pairing already
  exchanges both public keys and both people compared fingerprints. What stops a Mac being
  controlled is its own hosting switch.
- Revoke: remove the entry, send `SESSION_END` with `revoked`, and close any active session from
  that device. It must pair again from scratch.
- Hosting off: reject new sessions with `remote_access_disabled`, end existing ones, stop Bonjour,
  close the endpoint. On: reverse all of that. This switch is local-only and cannot be flipped
  remotely — that is the point of it.

---

## 21. Validation and rate limits

All network input is untrusted, including from paired devices.

- Every signaling payload and data channel message is validated against its JSON Schema before use. Unknown fields are ignored. Unknown `type` on a data channel is dropped and counted. Unknown `type` in signaling is rejected.
- Coordinates outside 0..1 are dropped. Relative deltas beyond 4096 points are dropped. Scroll deltas beyond 10000 points are dropped.
- Unknown key codes are dropped.
- Rate limits on the host per session: 300 mouse events per second, 100 key events per second, 50 text events per second. Excess is dropped.
- 100 malformed messages within a minute end the session with `error`.
- Text messages longer than 256 code points are dropped.
- A malformed message must never crash the agent. Parsing is wrapped, and any thrown error drops that message only.

---

## 22. Logging

Log structured events with device_id, session_id, message type, path, and stats such as RTT and bitrate.

Never log:

- Private keys, pairing codes, nonces after use.
- Contents of `text`, `key_down`, `key_up`, or any input coordinates.
- Clipboard or file contents when those features exist.
- Video frames or screenshots. Never write frames to disk.
- SDP outside of a debug build, because it contains addresses.

---

## 23. Threat model

| Threat | Mitigation |
|---|---|
| Unknown device discovers the Mac Mini | Allowlist of public keys, mutual challenge-response, one rate-limited rejection, no session state for strangers. |
| Compromised rendezvous server | Signed envelopes bind SDP fingerprints. Server cannot MITM, cannot view or inject. It can only deny service and observe presence metadata. |
| Compromised TURN | Sees encrypted packets, timing, and volume. Credentials expire in 2 hours. |
| Attacker on the LAN during pairing | Pairing proof requires the QR. Fingerprint comparison defeats key substitution. Host key hash in the QR defeats a fake host. |
| Malicious or malformed input from a paired device | Strict schema, clamping, rate limits, no command messages, crash isolation per message. |
| Stolen controller | Revoke on the Mac Mini. Trust sync removes it from the server. Hardware-backed keys on the stolen device cannot be extracted, but the device can still be used until revoked, so revoke promptly. |
| Replayed signaling | Per-session monotonic `seq`, timestamp window, single-use nonces. |
| Someone watches through the Mac Mini unnoticed | Menu bar indicator and notifications on every session start. |

---

## 24. Security rules for AI coding agents

1. Never expose VNC, RDP, SSH, or any control port to the Internet. Only the rendezvous server and TURN listen publicly, and neither carries control data.
2. Never implement custom cryptography. Use the platform primitives listed in section 5 and WebRTC's own DTLS-SRTP.
3. Never store or transmit private keys off the device.
4. Never log private keys, pairing codes, input contents, clipboard, or screen data.
5. Never add a message type that executes commands, scripts, or file operations.
6. Every data channel message is processed only after the session passed mutual authentication.
7. Pairing requires explicit approval on the Mac Mini.
8. Revoked devices cannot reconnect, resume, or relay.
9. TURN is a packet relay, never a trusted endpoint.
10. Validate every network message against its schema before touching it.
11. Sessions expire. Resumption is signed and windowed.
12. Fail closed. When in doubt, close the connection.
13. Signaling transport is never trusted for integrity. Only envelope signatures are.
14. Do not add features that need the server to hold durable state without updating this document.

---

## 25. Deployment

What is actually deployed:

```text
Mac mini   ~/Applications/PRC.app under the LaunchAgent com.prc.app, hosting on,
           Screen Recording and Accessibility granted
MacBook    the same app, the same way
Phone      the debug APK, installed with adb
Network    Tailscale on all three, one tailnet, free plan.
           No server, no TURN, no domain, no VPS, no recurring cost.
```

Development:

```text
Both halves in one process: swift test in apps/mac-controller runs a real agent
in-process with a synthetic screen. npm run e2e drives the real prc-agent binary
from Node. Neither needs a display or a permission.
```

The Internet deployment below is **not built**, and is kept in case a tailnet ever stops being
acceptable:

```text
Small VPS
  Caddy or nginx      TLS termination, WSS reverse proxy to the rendezvous server
  rendezvous server   Node 22, Docker
  coturn              Docker, host networking, ports 3478 udp/tcp and 5349 tcp,
                      relay range 49160-49200 udp, use-auth-secret
```

Only the reverse proxy and coturn would be exposed; the rendezvous server would listen on
localhost. Do not trade security for cost.

---

## 26. Repository structure

```text
prc/
  docs/
    spec.md                 this document
    implementation.md       what exists, and what it cost to learn
  apps/
    prc/                    the Mac app: menu bar plus a window, hosts and controls
    android/                the phone app: controls only
    mac-agent/              PRCAgentCore, the hosting half, plus the prc-agent CLI
    mac-controller/         PRCControllerCore, the controlling half, plus prc-controller-cli
  packages/
    protocol/               the single source of truth
      schemas/              JSON Schema for every envelope, payload, and data channel message
      keycodes/             W3C code -> macOS virtual key, W3C code -> Android KeyEvent
      vectors/              signing inputs, signatures, pairing proofs, receiver cases
      generated/            types produced by codegen, committed
      src/                  the TypeScript reference implementation
    swift/                  PRCIdentity, PRCProtocol, PRCPeers, PRCLocalControl
  tools/
    e2e/                    headless end-to-end test driving the real agent binary from Node
    web-harness/            browser test client, dev only
  scripts/                  build, install, uninstall, draw the app icon
  assets/                   AppIcon.icns
  services/, infra/         empty: the rendezvous server and TURN were deferred
  README.md
```

Two differences from what v2 planned. There is no separate `identity` package: the per-platform key
wrappers live in `packages/swift/PRCIdentity` and in the phone's `device/` folder, because a wrapper
that thin is not worth a package boundary. And codegen emits TypeScript types and the Swift key
table only; the Kotlin protocol layer is written by hand against the same schemas and proved by the
same vectors, which is what actually matters.

The `protocol` package is the single source of truth. The vectors are run by all three
implementations, so a signature computed on Android verifies on both Macs.

---

## 27. Development order

Followed in this order, with the numbering kept so old notes still line up.

| Step | State |
|---|---|
| 1. Protocol package: schemas, key tables, vectors, TypeScript reference | done |
| 2. Identity on macOS and in the web harness, cross-checked with the vectors | done |
| 3. Agent core: signalling endpoint, session authentication, ScreenCaptureKit into libwebrtc | done |
| 4. Mac controller: discovery, authentication, video, mouse, keyboard, text | done |
| 5. Pairing and host UI: QR, proof, approval, peers, kill switch, power assertion, LaunchAgent | done, except the persistent signing identity, which the owner declined |
| 6. Rendezvous server and TURN | **not done.** Replaced by Tailscale, section 9.4 |
| 7. Reconnection: ICE restart, resume, network change | done on the Macs; the phone does not yet reconnect by itself |
| 8. Android controller: Keystore identity, authentication, video, touch and trackpad, keyboard | done |
| 9. Phase 2 | not started |

The two halves were then merged into one app per Mac, which was not in this list: it came from
using it, and finding that the machine you want to control is whichever one you are not sitting at.

---

## 28. Testing matrix

Every row that does not involve the rendezvous server or TURN has been exercised, most of them as
automated tests: see the suite table in [../README.md](../README.md) and the traps in
[implementation.md](implementation.md). The server rows are untested because there is no server.

| Scenario | Expected |
|---|---|
| Same LAN, no Internet | LAN signaling, Direct (LAN) media, full function |
| Same LAN, rendezvous server down | Same as above |
| Different networks, permissive NAT | Cloud signaling, Direct (Internet) media |
| Strict NAT on one side | Cloud signaling, Relayed media |
| TURN down, direct possible | Direct (Internet) still connects |
| Wi-Fi drop for 10 s | RECONNECTING, ICE restart, back to CONNECTED without re-auth prompt |
| Wi-Fi drop for 15 min | Resume rejected as expired, full re-authentication, no re-pairing |
| Controller IP changes | Reconnects, no re-pairing |
| Revoked controller | SESSION_REJECT revoked, server closes its connection with 4403 |
| Unknown device | SESSION_REJECT untrusted, then silence for a minute |
| Bad signature on any envelope | Message dropped, connection closed |
| Replayed envelope | Dropped by seq or ts |
| Server swaps DTLS fingerprint in SDP | Signature fails, session refused |
| Remote Access off | New sessions rejected, active session ended, Bonjour stops |
| Pairing proof wrong | bad_proof, three strikes cancel the pairing session |
| Pairing fingerprint mismatch | User declines, no key stored |
| Oversized or malformed data channel message | Dropped, agent keeps running |
| 500 mouse events per second | Excess dropped, no lag buildup |
| Display disconnected mid-session | display_info update or clean bye, agent keeps running |
| Mac Mini sleeps and wakes | Agent reconnects to the server, controller reconnects |
| Second controller connects | busy |

---

## 29. Acceptance criteria

Performance, as measured rather than as hoped:

| Criterion | Result |
|---|---|
| LAN: 1080p, up to 60 fps, pointer feels local | met: 1920x1080 at 52 to 58 fps, 8 to 12 ms round trip, Mac mini to MacBook over Wi-Fi |
| Internet, good conditions: 1080p at 30 fps | met over a tailnet with a direct path |
| Internet, poor conditions: automatic downgrade, no freeze | met: on a DERP relay at under a megabit the frame rate gives way and the picture stays sharp, which is the deliberate trade |
| No relay when direct works | met: ICE prefers direct, and the path is reported from `getStats` |
| Reconnect after a short interruption without user action | met on the Macs; the phone does not yet |
| Phone: 1080p H.264 rather than VP8 | met, after naming the codec on both sides and offering a level the picture fits in |

Security. Everything that does not depend on the deferred server holds:

- [x] Every signalling message is signed and verified, including the SDP, so the DTLS fingerprint is
      signed. Confirmed by the fingerprint-swap test.
- [x] Private keys are hardware-backed where available and never leave the device.
- [x] Pairing needs approval on the host and a fingerprint comparison on both sides.
- [x] Revocation ends active sessions and blocks resume.
- [x] Mutual challenge-response precedes every SDP exchange.
- [x] Hosting can be switched off locally and it stops everything.
- [x] No message type can execute commands or touch files.
- [x] Logs contain no input contents, keys, codes, or frames.
- [x] All messages are schema-validated. The malformed-input tests pass.
- [x] Sessions expire and resumption is signed.
- [x] Reconnection never skips verification.
- [x] Every session start is visible on the host.
- [x] No control port is exposed to the Internet: the only way in from outside is the tailnet.
- [ ] Devices authenticate to the rendezvous server — not applicable while there is no server. The
      code and vectors exist; nothing runs them but the tests.
- [ ] TURN credentials expire — same: implemented and tested, unused.

---

## 30. Later phases

Phase 2:

- Local cursor rendering with `cursor_position` and `cursor_shape` messages, capture with `showsCursor` false.
- Multiple monitors and monitor selection through `display_list`.
- Clipboard sync over `control`, opt-in per direction, never logged, never on the server.
- File transfer over a dedicated reliable channel with approval, progress, cancel, and size limits.
- Binary message encoding for the input channels.
- Native-resolution capture on the LAN path.
- Android hardware keyboard. The gestures listed here as future work were built instead, in
  section 4.3.
- Manual short pairing code as an alternative to QR. Pasting the full code as text already works,
  which took most of the need out of this.
- TLS on the LAN signaling endpoint.
- Explicit quality policy on top of the stats API.

Phase 3:

- Waking a sleeping host. On the LAN this is a magic packet, and the Mac mini already has
  `womp 1` on AC power; from outside the LAN it cannot work, because a magic packet does not route
  over a tailnet, so it needs something already awake at home to send it.
- Host status such as CPU, battery on a laptop host, uptime.
- Remote restart and shutdown as dedicated, explicitly confirmed message types, never a shell.
- Audio.
- Session history with metadata only.
- Connection quality dashboard and NAT diagnostics.

---

## 31. Decisions the owner has since made

1. **Automatic login versus FileVault.** Undecided, and it has not bitten yet: both Macs are logged
   in and stay that way. After a reboot, a Mac must be logged into in person before it can be
   controlled.
2. **VPS provider and domain.** Not needed. Tailscale replaced the rendezvous server and TURN.
3. **Pairing is LAN-only.** Confirmed, and accepted: a new device is paired at home.
4. **Busy policy.** Confirmed as written: the second controller is rejected as busy.
5. **Idle timeout default.** 120 minutes, as written.
6. **Code signing.** Decided against: ad-hoc signing, no certificate, and the permission prompts
   after a rebuild are accepted as the price. This overrides the advice in section 18.
