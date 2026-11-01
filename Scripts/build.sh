#!/bin/bash
# release build, app bundle, codesign
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/Rec.app"

swift build -c release 2>&1 | tail -3

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Rec" "$APP/Contents/MacOS/Rec"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# a stable signing identity keeps TCC permissions across rebuilds, ad-hoc does not
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Rec Development"; then
    IDENTITY="Rec Development"
else
    echo "note: ad-hoc signed. run Scripts/setup-signing.sh once so permissions survive rebuilds"
fi
codesign --force --sign "$IDENTITY" --identifier com.rec.app \
    --entitlements "$ROOT/Resources/Rec.entitlements" "$APP"
echo "built $APP (signed: $IDENTITY)"
