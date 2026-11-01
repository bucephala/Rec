#!/bin/bash
# stop the agent and remove everything except your recordings
set -uo pipefail
LABEL="com.rec.app"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x Rec 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Rec.app"
echo "removed. recordings are still in ~/Movies/Recordings"
