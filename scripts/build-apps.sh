#!/bin/bash
# Builds "PRC Agent.app" and "PRC Controller.app" into dist/.
#
#   scripts/build-apps.sh                       both apps, release build, ad-hoc signature
#   scripts/build-apps.sh controller            just one of them (agent | controller | all)
#   PRC_SIGN_IDENTITY="PRC Local Signing" scripts/build-apps.sh
#   CONFIG=debug scripts/build-apps.sh
#
# Ad-hoc signing is the default and needs no certificate. Its one side effect: macOS ties Screen
# Recording and Accessibility grants to the signature, and an ad-hoc signature changes per build,
# so the agent asks for those permissions again after a rebuild. Optional: create a free local
# identity once with scripts/make-signing-identity.sh and pass its name to avoid that.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
IDENTITY="${PRC_SIGN_IDENTITY:--}"
VERSION="${PRC_VERSION:-0.2.0-dev}"
DIST="$ROOT/dist"
mkdir -p "$DIST"

build() {
  echo "building $2 ($CONFIG)"
  (cd "$ROOT/$1" && swift build -c "$CONFIG" --product "$2" 2>&1 | tail -1)
}

# bundle <app name> <binary> <package dir> <bundle id> <LSUIElement true|false>
bundle() {
  local name="$1" bin="$2" pkg="$3" bid="$4" uielement="$5"
  local app="$DIST/$name.app"
  local build_dir="$ROOT/$pkg/.build/$CONFIG"
  local framework
  framework="$(find "$ROOT/$pkg/.build/artifacts" -maxdepth 6 -path '*macos*' -name WebRTC.framework | head -1)"
  [ -n "$framework" ] || { echo "WebRTC.framework not found under $pkg/.build/artifacts"; exit 1; }

  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
  cp "$build_dir/$bin" "$app/Contents/MacOS/$bin"
  cp -R "$framework" "$app/Contents/Frameworks/"
  # SwiftPM binaries carry an absolute rpath into .build; add the bundle's Frameworks folder too.
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/$bin" 2>/dev/null || true

  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$bin</string>
  <key>CFBundleIdentifier</key><string>$bid</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><$uielement/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Personal use.</string>
</dict>
</plist>
PLIST

  codesign --force --deep --sign "$IDENTITY" "$app" 2>&1 | grep -v 'replacing existing signature' || true
  codesign --verify --deep --strict "$app"
  local signer
  signer="$(codesign -dv "$app" 2>&1 | grep -E '^(Authority|Signature)=' | head -1)"
  echo "built $app  [$signer]"
}

WHAT="${1:-all}"
case "$WHAT" in
  agent|controller|all) ;;
  *) echo "usage: $0 [agent|controller|all]"; exit 2 ;;
esac

if [ "$WHAT" != "controller" ]; then
  build apps/mac-agent prc-agent-app
  bundle "PRC Agent" prc-agent-app apps/mac-agent com.prc.agent true
fi
if [ "$WHAT" != "agent" ]; then
  build apps/mac-controller prc-controller
  bundle "PRC Controller" prc-controller apps/mac-controller com.prc.controller false
fi

echo
echo "Install: scripts/install-launch-agent.sh (agent, starts at login)   scripts/install-controller.sh (controller, to ~/Applications)"
