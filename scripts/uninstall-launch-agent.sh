#!/bin/bash
set -euo pipefail
launchctl bootout "gui/$(id -u)/com.prc.agent" 2>/dev/null || true
pkill -x prc-agent-app 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.prc.agent.plist"
rm -rf "$HOME/Applications/PRC Agent.app"
echo "removed the PRC Agent LaunchAgent and app. Trusted devices and settings were left in place."
