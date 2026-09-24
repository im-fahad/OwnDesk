# OwnDesk as built

What exists today, how it works, and the things that were learned the hard way. The design this
follows is [spec.md](spec.md); where the two differ, this file describes reality and the spec has
been amended to match.

Written 2026-09-09 and brought up to date 2026-09-25. Tag `v0.1.0` is the last state where the
agent and the controller were separate apps. The project was called PRC until 2026-09-25.
[../README.md](../README.md) is the guided tour: the technology, the flow, and how to use it. This
file is the record of decisions and traps.

---

## 1. What it does

One Mac shows its screen to another and accepts its mouse and keyboard. It works on a LAN with no
server at all, and across the Internet over a Tailscale tailnet. Every message that sets up a
session is signed by a per-device key, so neither the network nor a relay can impersonate either
side or read anything.

As of v0.2 a single app fills both roles: a Mac can control, be controlled, or both. The Android
app is a controller only, and it is finished enough to use daily: it pairs by scanning the Mac's
code, shows the screen in H.264, and drives the pointer and keyboard with the gestures the
established remote desktop apps settled on.

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
  OwnDeskIdentity          P-256 keys, Secure Enclave, encodings, code-signing check
  OwnDeskProtocol          envelopes, receiver rules, payloads, data channel codec, pairing
  OwnDeskPeers             the peer list: who is paired, and whether it can host
  OwnDeskLocalControl      a same-user control channel so scripts can drive OwnDesk.app
apps/owndesk               the Mac app: menu bar plus a window, hosts and controls
apps/android               the phone app: controls only, with video and touch input
apps/mac-agent             hosting half (OwnDeskAgentCore) plus the headless owndesk-agent CLI
apps/mac-controller        controlling half (OwnDeskControllerCore) plus owndesk-controller-cli
tools/e2e                  headless end-to-end test driving the real agent binary from Node
tools/web-harness          browser controller, development only
scripts/                   build, install, uninstall, draw the app icon
assets/                    AppIcon.icns, which the build copies into every bundle
```

The icon is drawn, not painted: `scripts/make-app-icon.swift` renders it as vectors at each size
and packs the result with `iconutil`. Run it only when the artwork changes, since the build uses
the committed `assets/AppIcon.icns`.

The v0.1 SwiftUI app targets in `apps/mac-agent` and `apps/mac-controller` were removed once
`apps/owndesk` replaced them; their libraries and CLIs stay.

## 3. How a session happens

1. **Discovery.** The host advertises `_owndesk._tcp` over Bonjour with its device id in the
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

### OwnDeskPeers

One record per peer holding the key once and two flags: **may control us** and **we may control
it**. Key lookups are gated on the relevant flag, so a record without it fails verification closed
rather than relying on a check at the call site.

Between two Macs a pairing grants both. **We may control it** is always set for a Mac: whether it
lets us in is that Mac's decision, not ours. An earlier build had a switch for it on each side, and
that was a trap: switching control off on one Mac also switched it off on the other the first time
it was refused, and switching it back on then needed both Macs, with nothing saying so. **May control
us** is the one switch, "Allow it to control this Mac", on after pairing. Off keeps the pairing, and
the device's next request gets `SESSION_REJECT revoked` rather than `untrusted`, so it says why
instead of dropping the pairing. For that the agent now verifies any paired device's envelopes and
checks the switch at `SESSION_REQUEST`; nothing starts without one. What ends a pairing is
unpairing, on either side. A phone has only **may control us**, because it cannot host.

### The app

`apps/owndesk` runs as a menu bar item with a window on demand. Hosting is off by default and turning
it on is what constructs the hosting half, so a Mac used only as a controller never touches screen
capture and is never asked for those permissions.

### The phone

One identity per phone, an ECDSA P-256 key generated in the Android Keystore and never exportable,
which is the same promise the Macs get from the Secure Enclave. The protocol layer is a direct
translation of the TypeScript reference and is checked against the same vectors, so the three
implementations agree by construction rather than by inspection. Pairing and the session handshake
work, and so do video and input: the phone offers, the Mac answers, and the picture arrives on the
same socket the handshake used. Pairing is done by scanning the QR the Mac draws, decoded on the
phone from the camera's brightness plane with no Play Services and nothing uploaded. Touches are
absolute rather than trackpad-relative, because on a phone the whole desktop is visible at once, so
putting the pointer where the finger lands is both quicker and easier to aim. Pinching magnifies the
picture on the phone alone and asks the Mac for nothing, which costs no bandwidth and keeps working
on a poor link; the arithmetic that keeps the pointer exact under magnification lives in
`PointerMapping` and is tested without a phone. The controls live on a sidebar drawn over the black
bar beside the picture, so they cost no part of the Mac's screen: touch or trackpad, the keyboard,
session info, and end. The icons have no labels and name themselves when held, which is where
Android puts the name of a control that has no caption. The info panel reports what the connection
is actually doing, read from `getStats` rather than guessed, and that panel is what found the two
codec bugs below. A debug build can be driven by intent extras, the way the Mac app can be driven by
its control CLI, which is how the flow is tested without typing on the phone.

### Testing without hardware

- `--synthetic-screen` streams a generated pattern, so video paths can be exercised with no Screen
  Recording permission and no display.
- `OwnDeskLocalControl` gives the app a loopback port and a token in its data folder, so a script can
  read state, connect, measure, and take access away. It cannot switch hosting on, pair, approve,
  or grant a permission: any program running as the user can read the token, and the app holds
  Screen Recording and Accessibility, so those stay clicks.
- `tools/e2e` spawns the real agent binary and drives it from Node using werift, a WebRTC
  implementation independent of libwebrtc, which is a genuine interoperability check.

## 5. Building, installing, testing

```sh
npm install
npm test                                   # protocol package
npm run e2e                                # end to end against the real agent binary
npm run android-frames                     # the phone's frames against the real schemas
(cd packages/swift && swift test)
(cd apps/mac-agent && swift test)
(cd apps/mac-controller && swift test)
(cd apps/android && ANDROID_HOME=~/Library/Android/sdk ./gradlew :app:testDebugUnitTest)

scripts/build-apps.sh owndesk                  # dist/OwnDesk.app, ad-hoc signed
scripts/install-owndesk.sh                     # ~/Applications, menu bar, starts at login
scripts/install-owndesk.sh --stage             # copy only, for a Mac you are away from
scripts/install-owndesk.sh --replace-agent     # also remove an old v0.1 "PRC Agent"

cd apps/android && ANDROID_HOME=~/Library/Android/sdk ./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Suite sizes, all passing on 2026-09-25: protocol 27, packages/swift 34, agent 52, controller 17,
android 61, end to end 17 steps, android frames 13.

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

**The Dock icon follows the window, and the policy change costs the video.** The app is an
accessory while it lives in the menu bar, and a normal app while a window is open, so a Mac started
at login adds no Dock icon and an open window can take keyboard focus. Changing the activation
policy leaves an existing Metal-backed video view drawing nothing, so every change now posts a
notification and the video view is rebuilt with a fresh id. The close button is redirected to put
the window away rather than close it, because closing destroys the scene's views and SwiftUI's
replacement window comes back black. Quit really quits: the launch agent restarts the app only
after a crash, never after the owner chose Quit.

**State an H.264 level the picture actually fits in.** Android offers level 3.1, whose ceiling is
1280x720. A Mac that cannot meet the level in the offer does not complain: it quietly encodes VP8,
and the only symptoms are a picture costing ten to twenty times the bandwidth and arriving at a
third of the frame rate. Raising the offer to 4.2 fixed a 1080p Mac and still failed on a 1920x1200
one, because that resolution needs more macroblocks than 4.2 allows. The phone now asks its own
decoder what it supports and offers that, capped at 5.2: libwebrtc's parser knows no level above
5.2, and claiming 6.2 makes the Mac discard the H.264 line entirely and the session dies during
negotiation. Measured against a 1920x1200 desktop: VP8 at 3000 kbps became H.264 at 120 kbps, same
resolution, same thirty frames a second.

**Say which codec you want, or you will get VP8.** Neither side stated a preference, so the phone's
offer listed VP8 first, the Mac agreed, and a Mac with a hardware H.264 encoder spent its time
encoding VP8 in software: eight to seventeen frames a second, where H.264 gives full motion. The
phone now puts H.264 first in its offer, and the host names H.264 constrained baseline as its
preferred codec rather than accepting whatever the factory lists first. The phone's session panel is
what found this, which is the argument for showing real numbers instead of a spinner.

**A pairing code is decoded on the phone.** Scanning uses the camera's brightness plane and a
barcode reader compiled into the app: no Play Services, no upload, nothing kept. Typing that code
by hand is the worst part of pairing, and the Mac already draws it as a QR.

**A scanner needs resolution and focus, and CameraX gives neither by default.** The first build
looked alive — preview moving, frames arriving — and never read a code. Analysis frames default to
640x480, which is not enough pixels for a QR holding a public key hash and several addresses, and
nothing ever asked the camera to focus, so the picture stayed soft at the distance a phone is
naturally held from a screen. The first fix asked for 1920x1080 analysis frames, a focus on open
and on tap, and the reader's `TRY_HARDER` hint.

That was not the end of it, and on a Redmi K80 it still read nothing. Three more things, found by
pulling the phone's own preview over adb and feeding it to decoders on a Mac:

- *Refocusing kills focus.* It also re-triggered autofocus every thirty empty frames, a little over
  a second at full rate, so the lens was always searching. Continuous autofocus left alone settles.
- *A phone cannot focus on a code small enough to fill its frame.* The Mac's code is a few
  centimetres wide, and a main camera will not focus much closer than ten. A 2x zoom lets it be held
  15 to 25 cm away with the code still large.
- *A bright screen eats the black.* Metered on a dark window, the white of the code burns out and
  bleeds into the black modules until the finder patterns lose their 1:1:3:1:1 shape and zxing
  cannot even locate the code, although Apple's Vision could still read the same picture. The
  scanner now meters on the middle of the code at -2 EV, and each frame is also tried with its dark
  areas grown back by one to three pixels, which is what made a captured failing frame read.

The Mac helps from its side too: the code is drawn at 300 points on a white margin of about four
modules, the quiet zone a QR needs and `CIQRCodeGenerator` does not add.

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

**A stream that keeps sending is not a stream that is working.** ScreenCaptureKit stops on display
sleep, screen lock and display reconfiguration, and never restarts. The agent used to declare
`onStopped` and never assign it, so the failure was logged and dropped; meanwhile the static-screen
repeat timer went on re-sending the last frame for ever. The result was the worst kind of bug:
frames arriving at a healthy rate, bitrate low because identical frames encode to almost nothing,
WebRTC's own freeze counters at zero, input still working — and a frozen picture that never came
back, not even after unlocking. Now `CaptureSupervisor` retries until capture both starts and
delivers a frame, and `capture_state` tells the controller which it is.

**Two signals, never one, when deciding capture is dead.** A motionless desktop produces no
complete frames either, so silence alone would have the agent restarting its own capture every few
seconds on an idle Mac. Liveness is measured from sample buffers of *any* status — an idle stream
still delivers them — and silence only counts when the window server agrees the screen is locked or
the display is asleep. `CaptureRepeatPolicy` holds that rule and is unit tested from both sides.

**Restarting is not recovering.** At the lock screen ScreenCaptureKit opens a stream quite happily
and then produces nothing. Reporting that as recovery puts the frozen picture back with no
explanation, so the supervisor waits for an actual frame before saying `active`.

**A waking display stops capture two or three more times before it settles.** Found by running the
real thing: `pmset displaysleepnow` during a live session, then `caffeinate -u`. Capture came back,
delivered a frame, and ScreenCaptureKit stopped it again within a second with "Failed to find any
displays or windows to capture" while the display list churned — three pause/resume cycles in four
seconds, flickering the controller's banner. Two rules came out of that, and both are load-bearing:
a freshly started capture is given `settleAfterStartMs` before anything may call it dead, and an
outage is not announced to the controller until it has lasted `reportAfterMs`. Restarting through a
blip is right; narrating it is not.

**The phone had been throwing the control channel away.** `WebRTCClient`'s data channel observer
registered an `onMessage` with an empty body, so every message the Mac sent was discarded. That
made `capture_state` invisible, and it also meant a `display_info` sent mid-session never landed:
pointer mapping kept using the size learned at SESSION_ACCEPT, so a host display that changed size
would have put every touch in the wrong place. `DataChannel.parse` now decodes the three messages
the phone acts on and returns null for everything else, because a newer Mac is allowed to send
types this build has never heard of and dropping the session over that would be worse.

**Permission is not the same as capability.** Pairing records both directions, which is right for
two Macs and wrong for a phone: an Android controller runs no hosting half and has no address to
reach, so `weMayControl` on it produced a row under "Macs you can control" whose dot could never go
green. It read as a Mac that was offline. `Peer.canHost` now says what a device is able to do and
`isHostForUs` combines it with permission; the phone moves to the section for devices that drive
this Mac, where no reachability dot is drawn because there is nothing to reach. `hostKey` is gated
the same way, so a phone's key can never pass as a host's. Old records need no migration, because
the rule is computed rather than stored.

**A Mac hears its own advertisement.** Bonjour returns this Mac's own service, over loopback as
well as the LAN, so it listed itself under "Nearby, not paired" as though it were a stranger. The
discovery sink filters on its own device id.

**A stored address is a guess about the past.** The phone kept the addresses each Mac advertised at
pairing time, and a router that moves a lease makes them wrong: the MacBook paired at .50 answered
at .51, the mini paired at .55 answered at .52. With Tailscale off, nothing reachable was left in
the list, so a Mac sitting on the same Wi-Fi showed a grey dot and could only be reached by typing
an address by hand. The phone now browses `_owndesk._tcp` with `NsdManager` and matches the
`id` in the TXT record against its peer list, which is the Mac saying where it is now. The answer
goes to the front of `addresses`, capped at six, so the dot, the connect path and the address
dialog all get it at once — everything funnels through `Peer.candidates()`. Two details: NsdManager
resolves one service at a time and a second request while one is in flight is simply lost, so they
queue; and discovery is a convenience, never a requirement, because a network that forbids
multicast must still fall back to the stored list.

**A `lateinit` that nothing assigns is a crash waiting for the gesture that reads it.** `holdMark`,
the circle shown while a drag holds the mouse button down, was declared and never created: three
reads, no assignment, and the compiler is happy because that is what `lateinit` promises. Every
tap-twice-and-hold — the gesture for selecting text and dragging windows — killed the app, and
because `buttonDown` is sent just before the read, it did so with the Mac's left button held. Two
of these sat in the phone's dropbox from 2026-09-10 and nobody had looked. Worth an occasional
`adb shell dumpsys dropbox --print` and a sweep of `~/Library/Logs/DiagnosticReports`: the devices
keep a record of every crash, whether or not anyone was watching when it happened.

**Verify this one by watching frames, not the connection.** The proof that the fix works is the
frame rate going to **0** for the length of the outage. Before the fix it stayed at ~30 fps on a
frozen picture, because the repeat timer kept feeding the encoder the same frame — which is exactly
why nothing downstream noticed.

**Measure, do not squint.** Stream statistics (`app stats`) and a pixel-brightness check on
screenshots settled several questions that eyes could not.

## 7. Where it runs today

The author's own setup: a Mac mini and a MacBook, each running only `~/Applications/OwnDesk.app`
under its LaunchAgent with hosting on, each holding the other in both directions, and an Android
phone running the debug build as a controller, reaching both Macs on the LAN and over the tailnet.

Both Macs kept their identities through the move from the split apps and through the rename from
PRC, so neither needed pairing again. The phone pairs once more after the rename, because its new
application id gives it a new Keystore key.

Measured: LAN 1920x1080 at 52 to 58 fps with 8 to 12 ms round trip. Over Tailscale, when it cannot
connect the two directly, it relays and the round trip becomes several hundred milliseconds at
under a megabit; the picture stays sharp and the frame rate gives way. `tailscale netcheck` shows
why a direct path is unavailable: on this network the home router offers no port mapping.

## 8. Not built

- The rendezvous server and TURN. Deferred in favour of Tailscale; the protocol still describes
  them.
- Audio from host to controller. Possible, but this WebRTC build can only take audio from a real
  input device on macOS, so it means carrying encoded audio on a data channel of our own.
- Clipboard, file transfer, multiple monitors, local cursor rendering.
- Waking a sleeping host. The Mac mini has `womp 1` on AC power, so a magic packet on the LAN would
  work; from outside the LAN it cannot, because a magic packet does not route over a tailnet.
- Cancelling an attempt while it is connecting, on either controller.
- The Mac app does not browse for Macs the way the phone now does, so a Mac whose address moved is
  still found only because `firstReachable` probes every candidate in parallel.
- The phone ignores `pong`, so it has no round trip time of its own from the control channel (the
  info panel takes one from `getStats` instead), there is no ping keepalive from it, and it does
  not reconnect by itself when the network changes. It does now read `display_info`,
  `capture_state` and `bye`.

## 9. Conventions

Ask before committing. Keep `packages/protocol` as the source of truth and regenerate after
changing a schema or the key table. For local smoke runs use `--file-identity`, a temporary
`--data-dir`, and `--synthetic-screen`, so nothing prompts and nothing lands in the real
Application Support folder. For work across both Macs, copy the tree to the other machine and keep
its data outside the copied folder, since a sync with delete would erase it.
