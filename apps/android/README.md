# PRC on Android

The phone half of PRC. It pairs with a Mac and opens an authenticated session with it. Video and
touch input are not built yet; this is the handshake the rest will hang from.

The Macs can host or control. The phone only controls, which is why this app is much smaller than
`apps/prc`.

## What it does today

- Makes one identity per phone, an ECDSA P-256 key generated inside the Android Keystore and never
  exportable, and shows its fingerprint at the top of the screen.
- Pairs with a Mac from the code that Mac displays, proving possession of the code with an HMAC and
  checking that the Mac's key hashes to the id printed in the code. Both people compare fingerprints.
- Signs every signaling envelope and applies the same receiver rules as the Macs, so a replayed,
  stale, misaddressed or unsigned message is refused.
- Runs the session handshake to the point where the Mac accepts and reports its display.

## Build and install

Needs a JDK 17 and the Android SDK. The Gradle wrapper is checked in.

    cd apps/android
    ANDROID_HOME=~/Library/Android/sdk ./gradlew :app:assembleDebug
    adb install -r app/build/outputs/apk/debug/app-debug.apk

`local.properties` is not checked in; either write `sdk.dir=...` into it or set `ANDROID_HOME`.

## Tests

    ANDROID_HOME=~/Library/Android/sdk ./gradlew :app:testDebugUnitTest

These run the vectors in `packages/protocol/vectors`, the same ones the TypeScript and Swift
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
