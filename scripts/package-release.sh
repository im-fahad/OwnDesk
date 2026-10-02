#!/bin/bash
# Packs a release into dist/release/: the Mac app as a zip with its installer, the Android APK, and
# their SHA-256 sums. The release workflow runs it on a tag; it also runs by hand after a build.
#
#   scripts/package-release.sh 0.4.0
#
# It expects dist/OwnDesk.app (scripts/build-apps.sh owndesk) and, if there is one, the release APK
# (apps/android: ./gradlew :app:assembleRelease). An APK that is not signed is left out, since
# Android refuses to install one.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: scripts/package-release.sh <version>}"
OUT="$ROOT/dist/release"
APP="$ROOT/dist/OwnDesk.app"
APK="$ROOT/apps/android/app/build/outputs/apk/release/app-release.apk"
[ -d "$APP" ] || { echo "build the Mac app first: scripts/build-apps.sh owndesk"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
NAME="OwnDesk-$VERSION-macos"
STAGE="$(mktemp -d)/$NAME"

# The same layout as the repository, so the install script runs from inside the download unchanged.
mkdir -p "$STAGE/dist" "$STAGE/scripts" "$STAGE/apps/owndesk/LaunchAgent"
ditto "$APP" "$STAGE/dist/OwnDesk.app"
cp "$ROOT/scripts/install-owndesk.sh" "$ROOT/scripts/uninstall-owndesk.sh" "$STAGE/scripts/"
cp "$ROOT/apps/owndesk/LaunchAgent/io.github.im-fahad.owndesk.plist" "$STAGE/apps/owndesk/LaunchAgent/"
cp "$ROOT/LICENSE" "$STAGE/"
cat > "$STAGE/INSTALL.txt" <<TXT
OwnDesk $VERSION for macOS 14 or newer, Apple silicon.

This build is signed ad hoc, without an Apple certificate, so macOS does not know who made it.
Clear the download mark once, then install:

  cd ~/Downloads/$NAME
  xattr -dr com.apple.quarantine .
  scripts/install-owndesk.sh

It goes to ~/Applications, appears in the menu bar, and starts again at login. Hosting stays off
until you switch on "Let others control it"; macOS then asks for Screen Recording and Accessibility.

To remove it: scripts/uninstall-owndesk.sh
The full guide: https://github.com/im-fahad/OwnDesk#6-user-guide
TXT
(cd "$(dirname "$STAGE")" && ditto -c -k --norsrc --noextattr --keepParent "$NAME" "$OUT/$NAME.zip")
rm -rf "$(dirname "$STAGE")"

if [ -f "$APK" ]; then
  if "${APKSIGNER:-apksigner}" verify "$APK" >/dev/null 2>&1; then
    cp "$APK" "$OUT/OwnDesk-$VERSION-android.apk"
  else
    echo "the release APK is not signed, so it is left out"
  fi
fi

(cd "$OUT" && shasum -a 256 OwnDesk-* > SHA256SUMS.txt)
ls -la "$OUT"
cat "$OUT/SHA256SUMS.txt"
