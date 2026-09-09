# PRC as built

What exists today, how it works, and the things that were learned the hard way. The design this
follows is [spec.md](spec.md); where the two differ, this file describes reality and the spec has
been amended to match.

Written 2026-09-09, at commit `9e2328b` on branch `v0.2-hybrid`. Tag `v0.1.0` on `main` is the
last state where the agent and the controller were separate apps.

---

## 1. What it does

One Mac shows its screen to another and accepts its mouse and keyboard. It works on a LAN with no
server at all, and across the Internet over a Tailscale tailnet. Every message that sets up a
session is signed by a per-device key, so neither the network nor a relay can impersonate either
side or read anything.

As of v0.2 a single app fills both roles: a Mac can control, be controlled, or both. Android will
be a controller only.

## 2. Repository map

```text
docs/                      spec.md (the design), this file
packages/protocol          the single source of truth for the wire format
  schemas/                 JSON Schema for every message, split by transport
  keycodes/                W3C key code tables for macOS and Android
  vectors/                 shared test vectors, run by TypeScript and Swift alike
  src/                     the TypeScript reference implementation
  scripts/                 codegen (types + the Swift key table) and vector generation
packages/swift             Swift libraries used by both halves
  PRCIdentity              P-256 keys, Secure Enclave, encodings, code-signing check
  PRCProtocol              envelopes, receiver rules, payloads, data channel codec, pairing
  PRCPeers                 the peer list: who is trusted, in which direction
  PRCLocalControl          a same-user control channel so scripts can drive the GUI apps
apps/prc                   the Mac app: menu bar plus a window, hosts and controls
apps/android               the phone app: controls only, with video and touch input
apps/mac-agent             hosting half (PRCAgentCore) plus the headless prc-agent CLI
apps/mac-controller        controlling half (PRCControllerCore) plus prc-controller-cli
tools/e2e                  headless end-to-end test driving the real agent binary from Node
tools/web-harness          browser controller, development only
scripts/                   build, install, uninstall, draw the app icon
assets/                    AppIcon.icns, which the build copies into every bundle
```

The icon is drawn, not painted: `scripts/make-app-icon.swift` renders it as vectors at each size
and packs the result with `iconutil`. Run it only when the artwork changes, since the build uses
the committed `assets/AppIcon.icns`.

`apps/mac-agent` and `apps/mac-controller` still carry their own SwiftUI app targets from v0.1.
Those are superseded by `apps/prc` and are due for removal; their libraries and CLIs stay.

## 3. How a session happens

1. **Discovery.** The host advertises `_prc._tcp` over Bonjour with its device id in the
   TXT record. Away from the LAN the controller uses a stored address instead, and tries every
   address it knows in parallel, taking the first that answers.
2. **Signalling.** The host serves a WebSocket on port 47500. There is no server in the middle;
   the design keeps room for one but Tailscale has made it unnecessary.
3. **Authentication.** Request, challenge, auth, accept. Both sides sign, both check the other's
   nonce. Only then is SDP exchanged, and because the SDP travels inside a signed envelope the
   DTLS fingerprint is signed too.
4. **Media.** The controller offers, the host answers. Video is H.264 from ScreenCaptureKit
   through VideoToolbox. Three data channels carry input and control.
5. **Input.** The controller maps pointer positions to normalised coordinates, the host turns them
   back into Quartz events.

## 4. The parts, and why they are shaped that way

### packages/protocol

JSON Schema is the source of truth, not the code. `npm run codegen` emits TypeScript types *and*
the Swift key code table, so the table cannot drift between platforms. `npm run vectors` writes
signing inputs, envelopes, pairing proofs and TURN credentials that both the TypeScript and Swift
test suites consume, which is what proves a message signed on one platform verifies on the other.

### Envelopes

Every signalling message is a signed envelope. The signature covers a fixed context label and eight
fields joined by newline, with the payload as base64 of the exact JSON bytes the sender produced,
so no canonical JSON is needed across three languages. Receiver rules run in a fixed order and any
failure is final: size, version, recipient, known sender, signature, clock skew, replay, schema.

`seq` restarts at 1 per session. In the empty session namespace it restarts per *attempt*: one
pairing exchange, or one session request and its answer. Both sides reset after the reply, so a
retry starts again at 1.

### PRCPeers

One record per peer holding the key once and two independent permissions: **may control us** and
**we may control it**. Key lookups are gated on the relevant permission, so revoking a direction
makes verification fail closed rather than relying on a check at the call site. A peer allowed
neither is dropped.

Pairing sets both directions. That costs nothing in trust, because a single pairing already
exchanges both public keys and both people compare fingerprints. What stops a Mac being controlled
is its own hosting switch, which is off until turned on.

### The app

`apps/prc` runs as a menu bar item with a window on demand. Hosting is off by default and turning
it on is what constructs the hosting half, so a Mac used only as a controller never touches screen
capture and is never asked for those permissions.

### The phone

One identity per phone, an ECDSA P-256 key generated in the Android Keystore and never exportable,
which is the same promise the Macs get from the Secure Enclave. The protocol layer is a direct
translation of the TypeScript reference and is checked against the same vectors, so the three
implementations agree by construction rather than by inspection. Pairing and the session handshake
work, and so do video and input: the phone offers, the Mac answers, and the picture arrives on the
same socket the handshake used. Touches are absolute rather than trackpad-relative, because on a
phone the whole desktop is visible at once, so putting the pointer where the finger lands is both
quicker and easier to aim. Pinching magnifies the picture on the phone alone and asks the Mac for
nothing, which costs no bandwidth and keeps working on a poor link; the arithmetic that keeps the
pointer exact under magnification lives in `PointerMapping` and is tested without a phone. A debug
build can be driven by intent extras, the way the Mac app can be
driven by its control CLI, which is how the flow is tested without typing on the phone.

### Testing without hardware

- `--synthetic-screen` streams a generated pattern, so video paths can be exercised with no Screen
  Recording permission and no display.
- `PRCLocalControl` gives each app a loopback port and a token in its data folder, so a script can
  press the same buttons a person would. This is how pairing, connecting and measuring were driven
  from a second Mac over SSH.
- `tools/e2e` spawns the real agent binary and drives it from Node using werift, a WebRTC
  implementation independent of libwebrtc, which is a genuine interoperability check.

## 5. Building, installing, testing

```sh
npm install
npm test                                   # protocol package
npm run e2e                                # end to end against the real agent binary
(cd packages/swift && swift test)
(cd apps/mac-agent && swift test)
(cd apps/mac-controller && swift test)

scripts/build-apps.sh prc                  # dist/PRC.app, ad-hoc signed
scripts/install-prc.sh                     # ~/Applications, menu bar, starts at login
scripts/install-prc.sh --stage             # copy only, for a Mac you are away from
scripts/install-prc.sh --replace-agent     # also remove the older split agent
```

Suite sizes at the time of writing: protocol 27, packages/swift 29, agent 25, controller 15, end to
end 16 steps.

## 6. Things that cost time, so they should not cost it twice

**Never change the app's activation policy at runtime.** Switching between accessory and regular
leaves an existing Metal-backed video view drawing nothing: frames still decode and the renderer
still reports their size, so everything looks healthy while the picture is black. The policy is set
once at launch.

**Never close the window to hide it.** Closing destroys the scene's views and the replacement
window gets a dead video view, with the same symptom. Order it out and back in instead.

**Ad-hoc signatures change every build.** macOS ties Screen Recording and Accessibility to the
signature, so after reinstalling, the switch in System Settings can read as on while the new build
has nothing. The install script clears the stale entry with `tccutil reset`. A free local signing
identity would end this, but the owner chose no certificates.

**Declare the real network path.** The controller used to claim `lan` always, so the host seeded a
LAN bitrate on a relayed link and the encoder collapsed to a soft picture. Tailscale addresses are
private but may be relayed, so they count as cloud.

**A desktop is text.** Degradation preference is `maintainResolution`: an idle screen sends almost
nothing, which starves the bandwidth estimate, and under `balanced` the encoder answers by
shrinking the picture. Measured over the same relay, `balanced` settled at 960x540 and
`maintainResolution` at 1920x1080.

**Absolute pointer moves need a timestamp gate.** They travel on an unordered channel with no
retransmits, so on a relayed link a reordered pair snaps the cursor backwards. The host ignores a
move older than the newest applied. Relative moves need no gate, being additive.

**One offer at a time.** The reconnect loop used to issue a fresh ICE restart every half second; on
a link with a 600 ms round trip a second offer left before the first was answered, and the late
answer killed the session. An offer is outstanding for ten seconds and late answers are ignored.

**A custom header is not a title bar.** The window draws its content under a transparent title
bar, so the app's own header covers it and AppKit never sees those clicks: dragging the window and
double clicking to zoom both stop working. The header's background view now does both itself, and
SwiftUI decides what counts as empty space, because it routes a click down to that view only when
none of the header's own controls wants it. Two approaches that do not work: AppKit hit testing
cannot tell blank header space from a SwiftUI button, since SwiftUI answers with one hosting view
for the whole area; and making the background refuse clicks gives native dragging but puts the
double click out of reach.

**Synthetic clicks need a mouse move first.** A test that posts a click at a point the cursor is
not already at makes the window jump by that distance during a drag, which reads as a broken
gesture. The event also needs its click count set, and the traffic lights are only twelve points
wide, so an aim a pixel out looks like a dead button. Getting this wrong sent several hours after
imaginary bugs.

**Codec names are upper case on the wire.** The phone's first session request was dropped in
silence: the schema lists the codec enum as `H264`, the phone sent `h264`, and a payload that fails
validation is refused without a reply, which looks exactly like a Mac that is asleep. When a
message vanishes, check it against the schema before checking the network.

**A video view told to fill the screen will stretch.** The renderer sizes its surface to the frame
and lets the compositor scale it to the view, so a 16:9 desktop across a 20:9 phone came out
stretched, and the pointer landed a quarter of a screen from the finger. The view has to measure
itself to the frame's shape and let the black bars fall where they will. The mapping was proved by
tapping known points and reading the Mac's real cursor, not by looking.

**Check the phone's frames against the schemas.** `npm run android-frames` validates every data
channel frame the Android app can send, using the same validator the host uses. It caught four
frames the Mac would have dropped in silence: the wrong application name in `hello`, an invented
`prefer` value, and a missing `nonce` and `reason` on `ping` and `bye`.

**Relative pointer moves must accumulate, not re-read the cursor.** Adding each delta to wherever
the system says the cursor is loses most of a fast drag, because the window server has not applied
the previous move yet. Measured from a phone in trackpad mode, between a third and a half of the
distance vanished, and raising the speed made it worse rather than better. The host now adds each
delta to the position it last asked for, and resynchronises only after a pause long enough to mean
the user let go.

**Probe every address at once.** A Mac advertises a local address and a tailnet address, and trying
them in turn means waiting out a timeout on the wrong network before the right one is attempted at
all, which reads as a phone that cannot connect from a cafe. Both halves now probe in parallel and
use the first that answers, remembering it for next time. The phone can also pin one by hand, which
is the answer when only Tailscale will reach a Mac.

**Copy the gestures people already know.** The phone's controls follow what Microsoft, Chrome
Remote Desktop, Splashtop and Jump Desktop settled on, including the one that looks odd until it is
explained: a drag with the button held has to be entered deliberately, by tapping twice and holding,
because a plain finger drag has to stay free to point at things. Without that gesture there is no
way to select text or move a window. The logic lives in `Gestures`, away from Android's event
classes, because multi-touch cannot be synthesised over the debugging bridge and this is the only
way to test it at all.

**Measure, do not squint.** Stream statistics (`app stats`) and a pixel-brightness check on
screenshots settled several questions that eyes could not.

## 7. Where it runs today

Both Macs run only `~/Applications/PRC.app` under the `com.prc.app` LaunchAgent, hosting on, with
Screen Recording and Accessibility granted. Identities survived the migration from the split apps,
so nothing needed re-pairing: Mac mini `25AA-F3B7-4F82`, MacBook `FF28-84B1-1F62`, each holding the
other in both directions.

Measured: LAN 1920x1080 at 52 to 58 fps with 8 to 12 ms round trip. Over Tailscale, when it cannot
connect the two directly, it relays and the round trip becomes several hundred milliseconds at
under a megabit; the picture stays sharp and the frame rate gives way. `tailscale netcheck` shows
why a direct path is unavailable: on this network the home router offers no port mapping.

## 8. Not built

- The rendezvous server and TURN. Deferred in favour of Tailscale; the protocol still describes
  them.
- Audio, in either direction.
- Audio from host to controller. Possible, but this WebRTC build can only take audio from a real
  input device on macOS, so it means carrying encoded audio on a data channel of our own.
- Clipboard, file transfer, multiple monitors, local cursor rendering.
- Retiring the two superseded app targets in `apps/mac-agent` and `apps/mac-controller`.

## 9. Conventions

Ask before committing. Keep `packages/protocol` as the source of truth and regenerate after
changing a schema or the key table. For local smoke runs use `--file-identity`, a temporary
`--data-dir`, and `--synthetic-screen`, so nothing prompts and nothing lands in the real
Application Support folder. For work across both Macs, copy the tree to the other machine and keep
its data outside the copied folder, since a sync with delete would erase it.
