#!/bin/bash
# Installs dist/PRC Agent.app to ~/Applications and registers it as a LaunchAgent that starts at
# login and restarts if it crashes (spec section 18). Run scripts/build-apps.sh first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/PRC Agent.app"
[ -d "$SRC" ] || { echo "build first: scripts/build-apps.sh"; exit 1; }

APPS="$HOME/Applications"
APP="$APPS/PRC Agent.app"
PLIST="$HOME/Library/LaunchAgents/com.prc.agent.plist"
LOG_DIR="$HOME/Library/Logs/PRC"
mkdir -p "$APPS" "$HOME/Library/LaunchAgents" "$LOG_DIR"

launchctl bootout "gui/$(id -u)/com.prc.agent" 2>/dev/null || true
pkill -x prc-agent-app 2>/dev/null || true
rm -rf "$APP"
cp -R "$SRC" "$APP"
sed -e "s|__APP_PATH__|$APP|g" -e "s|__LOG_DIR__|$LOG_DIR|g" "$ROOT/apps/mac-agent/LaunchAgent/com.prc.agent.plist" > "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $APP and started it. It will start at login and restart after a crash."
echo "Logs: $LOG_DIR. Remove with scripts/uninstall-launch-agent.sh"
