#!/bin/bash
# Removes the merged app and its LaunchAgent. Peers and settings are left in place.
set -euo pipefail
launchctl bootout "gui/$(id -u)/io.github.im-fahad.owndesk" 2>/dev/null || true
pkill -x owndesk 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/io.github.im-fahad.owndesk.plist"
rm -rf "$HOME/Applications/OwnDesk.app"
echo "removed OwnDesk.app and its LaunchAgent. ~/Library/Application Support/OwnDesk was left alone."
