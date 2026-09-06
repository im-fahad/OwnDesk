# Personal Remote Control System (PRC) --- Specification v2

Revision date: 2026-09-07
Supersedes: personal-remote-control-ai-agent-spec.md (v1)
Protocol version defined by this document: 1

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

## 1. Project goal

A private, self-hosted remote-control system for personal use.

- A Mac Mini is the remote host.
- A MacBook controls the Mac Mini.
- An Android phone controls the Mac Mini.
- Controllers connect from the same LAN or across the Internet.
- Low-latency screen viewing plus mouse and keyboard control.
- Secure device pairing and mandatory authentication on every session.
- Automatic connection fallback. No remote-control port is ever exposed directly to the Internet.

Personal use only. No public distribution.

---

## 2. Architecture

```text
                    +---------------------------+
                    |    Rendezvous Server      |
                    |  (cloud, optional)        |
                    |  WSS: presence + relay    |
                    |  Issues TURN credentials  |
                    |  Holds no durable state   |
                    +------------+--------------+
                                 |
                   signaling only (signed envelopes)
                                 |
            +--------------------+---------------------+
            |                                          |
            v                                          v
  +--------------------+                    +--------------------+
  |     MacBook        |                    |   Android Phone    |
  |    Controller      |                    |    Controller      |
  |  Swift + WebRTC    |                    |  Kotlin + WebRTC   |
  +---------+----------+                    +----------+---------+
            |                                          |
            |   LAN: signal directly to the agent      |
            |   over its embedded endpoint (Bonjour)   |
            |                                          |
            |          WebRTC (DTLS-SRTP)              |
            |   direct when possible, TURN when not    |
            +--------------------+---------------------+
                                 |
                                 v
                    +---------------------------+
                    |         Mac Mini          |
                    |        Remote Agent       |
                    |  Embedded signaling (WS)  |
                    |  ScreenCaptureKit         |
                    |  CGEvent input injection  |
                    |  Trusted device store     |
                    |  Menu bar UI              |
                    +---------------------------+
```

Two planes:

- **Control plane**: presence, pairing, session authentication, SDP, ICE. Carried by the agent's embedded endpoint on the LAN, or by the rendezvous server over the Internet. Every control-plane message is signed end to end. The transport is never trusted.
- **Data plane**: screen video and input events. Carried only inside the WebRTC connection. Never touches the server. TURN, when used, relays encrypted packets it cannot read.

---

## 3. Key decisions

| Decision | Choice | Reason |
|---|---|---|
| Identity key type | ECDSA P-256, SHA-256 | Supported by Secure Enclave, Android Keystore, CryptoKit, WebCrypto. Ed25519 is not hardware-backed on either platform. |
| Signature encoding | Raw r||s, 64 bytes, base64url | Uniform across platforms. Android must convert from DER. |
| Public key encoding | X9.63 uncompressed, 65 bytes, base64url | Universal. |
| Device ID | Lowercase hex SHA-256 of the 65-byte public key | Self-certifying. |
| Signaling message format | JSON envelope, payload as base64url of exact JSON bytes | Avoids canonical JSON across three languages. |
| LAN signaling | WebSocket served by the agent, advertised via Bonjour | LAN works with no Internet and no server. |
| Cloud signaling | WSS to the rendezvous server | Metadata privacy. Signed envelopes carry the real security. |
| Offerer | Controller | Controller creates data channels and receives video. |
| Codec | H.264 via VideoToolbox | Hardware encode on Mac, hardware decode on Android and Mac. |
| Fallback | Single ICE negotiation with all candidate types | ICE already picks the best path. |
| MacBook stack | Native Swift | Shares code with the agent. Web views swallow system shortcuts. |
| Android role | Trackpad and keyboard first, screen view second | Phone screen is not a desktop. |
| Pairing | LAN only, physical approval on the host | Removes remote pairing attack surface. |
| Concurrency | One active controller. Second request is rejected as busy. | Simplest safe MVP behavior. |
| Host runtime | LaunchAgent in the login session, KeepAlive | Restarts after crash and after login. |

---

## 4. Components

### 4.1 Mac Mini remote agent

Runs continuously in the user's login session as a LaunchAgent. Presents a menu bar UI.

Responsibilities:

- Own the host identity key in the Secure Enclave.
- Serve the embedded signaling endpoint on the LAN.
- Advertise itself via Bonjour.
- Connect outbound to the rendezvous server when one is configured and remote access is on.
- Keep the trusted-device store and push it to the rendezvous server.
- Run pairing with local user approval.
- Authenticate every session with challenge-response and verify every signed envelope.
- Capture the screen with ScreenCaptureKit and feed libwebrtc.
- Receive input on data channels, validate it, and inject it with CGEvent.
- Hold a power assertion while a session is active.
- Expose the Remote Access kill switch, trusted devices, active session, and pairing in the menu bar UI.
- Never execute arbitrary remote commands.

Required macOS permissions: Screen Recording and Accessibility. See section 18 for why signing matters here.

### 4.2 MacBook controller

Native Swift app using the WebRTC framework.

Responsibilities:

- Discover the host on the LAN via Bonjour. Fall back to the rendezvous server.
- Authenticate. Verify the host's signatures.
- Render the video track full-window. Map pointer position over the video to normalized host coordinates.
- Send absolute mouse moves, buttons, precise scroll, key events, and text.
- Capture as many system shortcuts as macOS allows when the window is focused, with a documented list of ones it cannot capture. Provide a toolbar for the rest, at minimum Cmd+Tab, Cmd+Q, and Cmd+Space.
- Show connection state and path: LAN direct, Internet direct, or relayed.
- Reconnect automatically.

### 4.3 Android controller

Kotlin, native UI, official WebRTC Android library.

Responsibilities:

- Discover via NSD on the LAN. Fall back to the rendezvous server.
- Authenticate. Verify the host's signatures.
- Trackpad mode: the whole screen is a touch surface sending relative moves, taps, two-finger scroll, long-press for right click.
- Screen mode: video rendered in a SurfaceViewRenderer with pinch zoom, taps sending absolute moves plus clicks.
- Soft keyboard sending text events and key events for non-printing keys.
- Foreground service keeping the connection alive while the app is in use.
- Reconnect automatically.

### 4.4 Rendezvous server

Node.js, TypeScript, one WebSocket endpoint, one health endpoint. Deployed behind a TLS reverse proxy.

Does:

- Authenticate connecting devices by identity key against an allowlist pushed by the host.
- Track presence.
- Relay opaque signed envelopes between the host and its trusted controllers.
- Issue time-limited TURN credentials.

Does not:

- Store anything durable. The allowlist lives in memory and is re-pushed by the host on every connect.
- Inspect, log, or verify the inner envelopes beyond routing fields.
- Carry video, input, clipboard, or files. Ever.
- Have any REST API for device management.

### 4.5 TURN

coturn, on the same VPS, using time-limited credentials (`use-auth-secret`). Treated as an untrusted packet relay.

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
| Android | Android Keystore EC P-256, `setIsStrongBoxBacked(true)` when available, otherwise TEE. Signatures come back DER-encoded and must be converted to raw r||s. |

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
7. `seq` is greater than the last accepted `seq` from this sender for this session. `seq` starts at 1 per session and per pairing attempt.
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

Reasons: `untrusted`, `revoked`, `remote_access_disabled`, `busy`, `auth_failed`, `version_unsupported`, `expired`, `malformed`.

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

Reasons: `user`, `idle_timeout`, `revoked`, `remote_access_disabled`, `replaced`, `error`.

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
3. Else, or if that fails: open WSS to the rendezvous server. path = "cloud"
4. If the LAN signaling drops mid-session, retry LAN once, then cloud.
```

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

### 9.4 Alternative: private overlay network instead of the rendezvous server

For a zero-cost deployment the three devices can join a Tailscale tailnet on the free plan. The agent's embedded endpoint is then reachable over the tailnet from anywhere, so controllers use the `lan` signaling path against the stored tailnet address, ICE gathers host candidates on the tailnet interface, and Tailscale's own relays replace TURN. No rendezvous server, TURN, VPS, or domain is needed. Signed envelopes still protect against the overlay operator exactly as they protect against the rendezvous server. The apps do not change: the controller keeps a list of known host addresses to try after Bonjour fails, and the rendezvous path remains available for later.

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

## 11. Rendezvous server protocol

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
| `mouse_move` | `display_id` string, `x` 0..1, `y` 0..1 | Absolute, normalized to the streamed display. Used by the MacBook and Android screen mode. |
| `mouse_move_rel` | `dx`, `dy` in host points | Relative. Used by Android trackpad mode. Host applies its own acceleration curve. |
| `mouse_down` | `button`: `left`, `right`, `middle` | Host computes click count from timing and position and sets `mouseEventClickState`. |
| `mouse_up` | `button` | |
| `scroll` | `dx`, `dy` in points, `precise` bool, `phase`: `began`, `changed`, `ended`, `momentum`, or omitted | Precise true for trackpad and touch, false for wheel notches. |
| `key_down` | `code` string, `modifiers` array, `repeat` bool | `code` uses W3C UI Events `KeyboardEvent.code` names such as `KeyA`, `ShiftLeft`, `MetaLeft`, `Enter`, `ArrowUp`, `F5`. Host maps to macOS virtual key codes. |
| `key_up` | `code`, `modifiers` | |
| `text` | `text` string, at most 256 code points | Inserted with `keyboardSetUnicodeString`. Used for soft keyboards, IME output, and pasted text. Never logged. |

`modifiers` values: `shift`, `control`, `alt`, `meta`, `capslock`. The host also tracks modifier state from its own key events and uses the union.

### 13.2 Control channel

| type | Direction | Fields | Notes |
|---|---|---|---|
| `hello` | both | `versions`, `app`, `app_version` | First message on `control`. Version mismatch closes the session with `bye`. |
| `display_info` | host to controller | `display_id`, `width_px`, `height_px`, `scale` | Sent on open and whenever the streamed display changes. Controllers must handle a change mid-session. |
| `stream_settings` | controller to host | `max_height`, `max_fps`, `prefer`: `latency` or `quality` | Hints. Host clamps to its own limits. |
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
- `degradationPreference`: `balanced`.
- Keyframe on request only. libwebrtc handles PLI and FIR.

Static screens: ScreenCaptureKit delivers frames only on change. Re-submit the last frame at 2 fps so the encoder keeps a steady cadence and freshly connected decoders converge quickly.

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

The controller may send `stream_settings` to lower the caps, for instance on a metered mobile connection. Phase 2 can add an explicit quality policy on top of the stats API if the defaults prove insufficient.

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
- **Signing**: macOS ties the Screen Recording and Accessibility grants to the app's code-signing identity. Ad-hoc signatures change every build and the grants vanish. Use a persistent signing identity from the first day, ideally a Developer ID, or at minimum a self-signed certificate created once in Keychain Access and reused. Notarization is only needed if the app is distributed.
- **LaunchAgent**: `KeepAlive` true, `RunAtLoad` true, so the agent survives crashes and comes back after login.

---

## 19. Host UI

Menu bar app with a status icon: grey when idle, green with the controller's name when connected.

```text
Remote Access            [ ON ]
Rendezvous server        connected as Mac Mini M4
LAN discovery            advertising on port 47500

Active session
  My MacBook     Direct (LAN)  1080p60  RTT 3 ms    [Disconnect]

Trusted devices
  My MacBook     paired 2026-09-07   last seen now        [Revoke]
  Pixel 9                paired 2026-09-07   last seen yesterday  [Revoke]

[Pair New Device]
[Settings]  rendezvous URL, idle timeout, max bitrate
```

A system notification fires when a session starts and when one ends. The user must always be able to see that someone is connected.

---

## 20. Trusted devices, revocation, kill switch

- The trusted-device store lives on the Mac Mini in Application Support, containing device_id, public key, name, type, paired date, last seen. No secrets, so no special protection beyond file permissions.
- Revoke: remove the entry, send `SESSION_END` with `revoked` and close any active session from that device, push `trust_sync` to the server. The device must pair again from scratch.
- Remote Access off: reject new sessions with `remote_access_disabled`, end existing sessions, stop Bonjour, close the LAN endpoint, disconnect from the rendezvous server. On: reverse all of that. This toggle is local-only and cannot be flipped remotely.

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

Development:

```text
Mac Mini agent + MacBook controller on one LAN, no server, LAN path only.
Optional: rendezvous server running on the MacBook for cloud-path testing.
```

Internet:

```text
Small VPS
  Caddy or nginx      TLS termination, WSS reverse proxy to the rendezvous server
  rendezvous server   Node 22, Docker
  coturn              Docker, host networking, ports 3478 udp/tcp and 5349 tcp,
                      relay range 49160-49200 udp, use-auth-secret
```

Only the reverse proxy and coturn are exposed. The rendezvous server listens on localhost.

Zero-cost alternative (section 9.4):

```text
Tailscale free plan on the Mac Mini, MacBook, and phone.
No server, no TURN, no domain. Controllers connect to the agent's
embedded endpoint over the tailnet.
```

Cost: all software is free. The VPS is the only recurring cost and TURN bandwidth is the only variable. Do not trade security for cost.

---

## 26. Repository structure

```text
prc/
  apps/
    mac-agent/             Swift, menu bar app, embedded signaling, capture, injection
    mac-controller/        Swift
    android-controller/    Kotlin
  services/
    rendezvous/            Node 22, TypeScript
  packages/
    protocol/
      schemas/             JSON Schema for every envelope, payload, and data channel message
      keycodes/            W3C code -> macOS virtual key, W3C code -> Android KeyEvent tables
      vectors/             Test vectors: signing inputs, signatures, pairing proofs
      generated/           Swift, Kotlin, TypeScript types produced by codegen, committed
    identity/              Per-platform thin wrappers: key generation, signing, encoding
  tools/
    web-harness/           Browser test client using WebCrypto P-256, dev only
  infra/
    docker/
    coturn/
    reverse-proxy/
  docs/
    architecture.md
    security.md
    protocol.md
    deployment.md
  README.md
```

The `protocol` package is the single source of truth. JSON Schema drives generated types for all three languages, and the test vectors are run by all three implementations in CI so a signature computed on Android verifies on the Mac.

---

## 27. Development order

1. **Protocol package.** Schemas, key code tables, signing test vectors. A TypeScript reference implementation of envelope signing and verification.
2. **Identity.** Key generation, signing, and verification on macOS and in the web harness. Cross-check with the vectors.
3. **Agent core.** Embedded signaling endpoint, session authentication, ScreenCaptureKit into libwebrtc. Verify with the web harness rendering video on the LAN.
4. **MacBook controller.** Discovery, authentication, video. Then absolute mouse. Then keyboard and text.
5. **Pairing and host UI.** QR, proof, approval, trusted devices, kill switch, session indicator, power assertion, LaunchAgent, persistent signing identity.
6. **Rendezvous server and TURN.** Server auth, trust sync, relay, TURN credentials, coturn, Docker, deploy. Test the cloud path from a phone hotspot.
7. **Reconnection.** ICE restart, resume, network change handling. Run the testing matrix.
8. **Android controller.** Identity in Keystore, discovery, authentication, trackpad mode, screen mode, soft keyboard.
9. **Phase 2** only after every acceptance criterion in section 29 passes.

---

## 28. Testing matrix

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

Performance:

- LAN: 1080p, up to 60 fps, pointer feels local.
- Internet, good conditions: 1080p at 30 fps.
- Internet, poor conditions: automatic downgrade, no freeze.
- No relay when direct works.
- Reconnect after a short interruption without user action.

Security, all must be true:

- [ ] Only the reverse proxy and coturn are reachable from the Internet.
- [ ] Every signaling message is signed and verified. Confirmed by the fingerprint-swap test.
- [ ] Devices authenticate to the rendezvous server. Unknown devices are closed.
- [ ] Private keys are hardware-backed where available and never leave the device.
- [ ] Pairing needs approval on the Mac Mini and a fingerprint comparison.
- [ ] Revocation ends active sessions and blocks resume and relay.
- [ ] Mutual challenge-response precedes every SDP exchange.
- [ ] Remote Access can be disabled locally and it stops everything.
- [ ] No message type can execute commands or touch files.
- [ ] Logs contain no input contents, keys, codes, or frames.
- [ ] TURN credentials expire.
- [ ] All messages are schema-validated. The malformed-input tests pass.
- [ ] Sessions expire and resumption is signed.
- [ ] Reconnection never skips verification.
- [ ] Every session start is visible on the Mac Mini.

---

## 30. Later phases

Phase 2:

- Local cursor rendering with `cursor_position` and `cursor_shape` messages, capture with `showsCursor` false.
- Multiple monitors and monitor selection through `display_list`.
- Clipboard sync over `control`, opt-in per direction, never logged, never on the server.
- File transfer over a dedicated reliable channel with approval, progress, cancel, and size limits.
- Binary message encoding for the input channels.
- Native-resolution capture on the LAN path.
- Android hardware keyboard, better gestures.
- Manual short pairing code as an alternative to QR.
- TLS on the LAN signaling endpoint.
- Explicit quality policy on top of the stats API.

Phase 3:

- Host status such as CPU, battery on a laptop host, uptime.
- Remote restart and shutdown as dedicated, explicitly confirmed message types, never a shell.
- Audio.
- Session history with metadata only.
- Connection quality dashboard and NAT diagnostics.

---

## 31. Open decisions for the owner

1. **Automatic login versus FileVault** on the Mac Mini. Automatic login makes the Mac reachable after a reboot. FileVault protects the disk if the Mac is stolen. They are mutually exclusive.
2. **VPS provider and domain** for the rendezvous server and TURN.
3. **Pairing is LAN-only** in this design. Confirm that pairing a new phone while away from home is acceptable to give up.
4. **Busy policy**: reject the second controller, or let the newest connection take over. This spec rejects.
5. **Idle timeout default**: this spec uses 120 minutes.
