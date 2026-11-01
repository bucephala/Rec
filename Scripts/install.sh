#!/bin/bash
# build, copy to ~/Applications, register the launchd agent, start it
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
LABEL="com.rec.app"
DEST="$HOME/Applications/Rec.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGS="$HOME/Library/Logs/Rec"

"$ROOT/Scripts/build.sh"

# stop whatever is running so the binary can be replaced
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x Rec 2>/dev/null || true
sleep 0.5

mkdir -p "$HOME/Applications" "$LOGS" "$HOME/Movies/Recordings" "$(dirname "$PLIST")"
rm -rf "$DEST"
cp -R "$ROOT/build/Rec.app" "$DEST"

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/Contents/MacOS/Rec</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOGS/rec.log</string>
    <key>StandardErrorPath</key>
    <string>$LOGS/rec.err.log</string>
</dict>
</plist>
PL

launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 1
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "installed and running. look for the record icon in the menu bar."
    echo "first run: allow Screen Recording (and Microphone) when macOS asks, then it is hands off."
else
    echo "installed but launchd did not report it running, check $LOGS/rec.err.log" >&2
    exit 1
fi
