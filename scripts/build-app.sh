#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"

APP="dist/NimbusTerm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/NimbusTerm" "$APP/Contents/MacOS/NimbusTerm"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/NimbusTerm.icns "$APP/Contents/Resources/NimbusTerm.icns"
cp Resources/Credits.rtf "$APP/Contents/Resources/Credits.rtf"
for lproj in Resources/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done
chmod +x "$APP/Contents/MacOS/NimbusTerm"

# Ad-hoc signature: enough for local use. Gatekeeper still asks on first launch.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

rm -f dist/NimbusTerm.zip
ditto -c -k --keepParent "$APP" "dist/NimbusTerm.zip"
echo "Built $APP and dist/NimbusTerm.zip"
