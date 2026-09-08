#!/bin/bash
# Removes the merged app and its LaunchAgent. Peers and settings are left in place.
set -euo pipefail
launchctl bootout "gui/$(id -u)/com.prc.app" 2>/dev/null || true
pkill -x prc 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.prc.app.plist"
rm -rf "$HOME/Applications/PRC.app"
echo "removed PRC.app and its LaunchAgent. ~/Library/Application Support/PRC was left alone."
