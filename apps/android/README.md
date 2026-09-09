# PRC on Android

The phone half of PRC. It pairs with a Mac, shows that Mac's screen, and drives its pointer and
keyboard.

The Macs can host or control. The phone only controls, which is why this app is much smaller than
`apps/prc`.

## What it does today

- Makes one identity per phone, an ECDSA P-256 key generated inside the Android Keystore and never
  exportable, and shows its fingerprint at the top of the screen.
- Pairs with a Mac from the code that Mac displays, proving possession of the code with an HMAC and
  checking that the Mac's key hashes to the id printed in the code. Both people compare fingerprints.
- Signs every signaling envelope and applies the same receiver rules as the Macs, so a replayed,
  stale, misaddressed or unsigned message is refused.
- Runs the session handshake, then offers a WebRTC connection the Mac answers, and shows the
  screen it sends.
- Sends input on the three data channels the protocol defines: pointer moves on the unordered one,
  clicks, scroll and typing on the reliable one.
- Magnifies the picture on the phone, since a desktop shrunk onto a phone has text a few pixels
  tall.

## Using it

Tap a paired Mac to open its screen. Then:

| Gesture | What the Mac sees |
| --- | --- |
| Tap | left click |
| Two quick taps | double click |
| Tap twice and hold, then drag | the button stays down, which is how text is selected and windows are moved |
| Hold one finger still | right click |
| Tap with two fingers | right click |
| Tap with three fingers | middle click |
| Drag one finger | moves the pointer |
| Drag two fingers | scroll, or pan the picture while it is magnified |
| Pinch | magnifies the picture on the phone, up to four times |
| Sidebar icons | touch or trackpad, keyboard, session info, end |

The sidebar sits on the black bar beside a 16:9 picture, so it costs no part of the Mac's screen.
The icons carry no labels; hold one and its name appears, which is where Android shows the name of
a control that has no caption. The info icon expands the sidebar and reports what the session is
actually doing: which Mac, over which address and route, the resolution, frame rate, bitrate,
codec, packets lost, jitter and round trip, read from the connection rather than guessed.

These follow the conventions the established remote desktop apps settled on, so they should already
be in your hands. The one worth knowing is the drag: no app treats a plain finger drag as a drag,
because then nothing could be pointed at without dragging it. Tapping twice and holding is how you
enter it, and a blue circle appears to say the button is down.

## Reaching a Mac

A Mac advertises every address it has when pairing: the one on the local network, and its Tailscale
addresses. All of them are probed at once when connecting, so the phone finds the Mac whether it is
in the same room or on the other side of the world, without waiting out a timeout on the wrong
network first. Whatever answered last time is tried first the next time.

Long press a Mac in the list for its options. **Choose an address** pins one, which is what to use
when only Tailscale will reach it and the local address belongs to some other network's router.
**Use any address** goes back to probing. The dot beside each Mac turns green when an address
answers.

Reaching a Mac over Tailscale needs Tailscale running on the phone and on that Mac, both signed
into the same tailnet.

## Touch or trackpad

**Touch** is absolute. The pointer goes where your finger lands. Quick, but a fingertip covers about
forty pixels of a desktop, so small targets are hard to hit.

**Trackpad** is relative. Your finger nudges the pointer from where it already is, like a laptop
trackpad, and a tap clicks where the pointer is. Slower to cross the screen, far easier to be
precise. The choice is remembered.

Pinching magnifies the picture on the phone and asks the Mac for nothing, so it costs no bandwidth
and works while the link is poor. The pointer stays exact while magnified.

## Build and install

Needs a JDK 17 and the Android SDK. The Gradle wrapper is checked in.

    cd apps/android
    ANDROID_HOME=~/Library/Android/sdk ./gradlew :app:assembleDebug
    adb install -r app/build/outputs/apk/debug/app-debug.apk

`local.properties` is not checked in; either write `sdk.dir=...` into it or set `ANDROID_HOME`.

## Tests

    ANDROID_HOME=~/Library/Android/sdk ./gradlew :app:testDebugUnitTest

There is a second check that runs from the repository root, `npm run android-frames`. It validates
every data channel frame the app can send against the protocol's own JSON Schemas, using the same
validator the Mac uses. Run `./gradlew :app:testDebugUnitTest` first, since that is what writes the
frames out.

The Gradle tests run the vectors in `packages/protocol/vectors`, the same ones the TypeScript and Swift
implementations run: device ids and fingerprints, the exact bytes an envelope signs, the pairing
proof, and sixteen receiver cases covering replay, tampering, clock skew and unknown senders. If
the phone disagrees with a vector it disagrees with both Macs, so these are the tests that matter.

## Driving it from a computer

A debug build accepts two intent extras, the way the Mac app can be driven by its control CLI. A
release build ignores them, so no other app can start a pairing.

    # pair, passing the Mac's code as base64url
    CODE=$(prc-controller-cli app offer-pairing --data-dir "$HOME/Library/Application Support/PRC" | head -1)
    adb shell am start -n com.prc.controller/.ui.MainActivity \
      --es pairing_code_b64 "$(printf '%s' "$CODE" | base64 | tr '+/' '-_' | tr -d '=')"

    # then approve on the Mac
    prc-controller-cli app approve --data-dir "$HOME/Library/Application Support/PRC"

    # connect, naming the Mac by the start of its fingerprint
    adb shell am start -n com.prc.controller/.ui.MainActivity --es connect 25AA

Everything the app prints on screen also goes to logcat under the tag `PRC`.

## Layout

    app/src/main/kotlin/com/prc/controller/
      protocol/   encodings, identity, envelopes, receiver rules, pairing proof, payload types
      device/     the Keystore identity and the list of paired Macs
      net/        the WebSocket and the address parsing that decides lan or cloud
      session/    pairing and the session handshake
      ui/         the one screen
