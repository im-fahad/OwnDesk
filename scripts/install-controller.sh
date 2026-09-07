#!/bin/bash
# Copies dist/PRC Controller.app to ~/Applications. Run scripts/build-apps.sh controller first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/PRC Controller.app"
[ -d "$SRC" ] || { echo "build first: scripts/build-apps.sh controller"; exit 1; }
APPS="$HOME/Applications"
APP="$APPS/PRC Controller.app"
mkdir -p "$APPS"
osascript -e 'tell application "PRC Controller" to quit' >/dev/null 2>&1 || true
rm -rf "$APP"
cp -R "$SRC" "$APP"
echo "installed $APP"
