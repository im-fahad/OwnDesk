#!/bin/bash
# Installs dist/PRC.app to ~/Applications and, unless --no-login, registers it to start at login.
#
#   scripts/build-apps.sh prc && scripts/install-prc.sh
#   scripts/install-prc.sh --no-login          install without starting it at login
#   scripts/install-prc.sh --stage             copy it into place but do not run it
#   scripts/install-prc.sh --replace-agent     also stop and remove the older split agent
#
# --stage is for a Mac you are away from: the app is ready but nothing starts, so an older agent
# keeps serving and its control file is left alone until you are there to finish the switch.
#
# Hosting stays off until you switch it on in the app, so installing this never makes a Mac
# remotely controllable on its own, and it will not fight an older agent for the port.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/PRC.app"
[ -d "$SRC" ] || { echo "build first: scripts/build-apps.sh prc"; exit 1; }

LOGIN=1
REPLACE_AGENT=0
STAGE=0
for arg in "$@"; do
  case "$arg" in
    --no-login) LOGIN=0 ;;
    --stage) STAGE=1; LOGIN=0 ;;
    --replace-agent) REPLACE_AGENT=1 ;;
    *) echo "unknown option $arg"; exit 2 ;;
  esac
done

APPS="$HOME/Applications"
APP="$APPS/PRC.app"
PLIST="$HOME/Library/LaunchAgents/com.prc.app.plist"
LOG_DIR="$HOME/Library/Logs/PRC"
mkdir -p "$APPS" "$HOME/Library/LaunchAgents" "$LOG_DIR"

if [ "$REPLACE_AGENT" = 1 ]; then
  echo "stopping the older split agent"
  launchctl bootout "gui/$(id -u)/com.prc.agent" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.prc.agent.plist"
  pkill -x prc-agent-app 2>/dev/null || true
  rm -rf "$APPS/PRC Agent.app"
fi

launchctl bootout "gui/$(id -u)/com.prc.app" 2>/dev/null || true
pkill -x prc 2>/dev/null || true
rm -rf "$APP"
cp -R "$SRC" "$APP"

# An ad-hoc signature changes per build and macOS binds permission grants to it, so an old entry in
# System Settings shows as on but does not apply. Clear it so the new build can register itself.
tccutil reset ScreenCapture com.prc.app >/dev/null 2>&1 || true
tccutil reset Accessibility com.prc.app >/dev/null 2>&1 || true

if [ "$STAGE" = 1 ]; then
  echo "staged $APP. Nothing is running yet."
  echo "When you are at this Mac, finish with:  scripts/install-prc.sh --replace-agent"
  exit 0
fi

if [ "$LOGIN" = 1 ]; then
  sed -e "s|__APP_PATH__|$APP|g" -e "s|__LOG_DIR__|$LOG_DIR|g" "$ROOT/apps/prc/LaunchAgent/com.prc.app.plist" > "$PLIST"
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "installed $APP and started it in the menu bar. It will come back at login."
else
  open "$APP"
  echo "installed $APP. It will not start at login; remove --no-login to change that."
fi

echo
echo "Hosting is off. Turn on \"Let other Macs control this one\" when you want this Mac reachable,"
echo "then grant Screen Recording and Accessibility when it asks. Logs: $LOG_DIR"
