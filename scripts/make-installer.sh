#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0}"
APP="dist/NimbusTerm.app"
BUILD="build/installer"
DMG="dist/NimbusTerm-$VERSION.dmg"
PKG="dist/NimbusTerm-$VERSION.pkg"

if [ ! -d "$APP" ]; then
  ./scripts/build-app.sh
fi

rm -rf "$BUILD"
mkdir -p "$BUILD" dist
swift scripts/make-installer-art.swift dmg "$BUILD/dmg-background.png"
swift scripts/make-installer-art.swift pkg "$BUILD/pkg-background.png"

# ---------- DMG: drag to Applications ----------
DMG_SRC="$BUILD/dmg-src"
mkdir -p "$DMG_SRC"
ditto "$APP" "$DMG_SRC/NimbusTerm.app"
xattr -cr "$DMG_SRC/NimbusTerm.app"
rm -f "$DMG"

if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "NimbusTerm $VERSION" \
    --volicon "Resources/NimbusTerm.icns" \
    --background "$BUILD/dmg-background.png" \
    --window-pos 200 120 \
    --window-size 660 420 \
    --text-size 13 \
    --icon-size 128 \
    --icon "NimbusTerm.app" 170 208 \
    --app-drop-link 490 208 \
    --hide-extension "NimbusTerm.app" \
    --no-internet-enable \
    --format UDZO \
    "$DMG" "$DMG_SRC"
else
  # Functional fallback if create-dmg is not installed: still a valid DMG.
  ln -sfn /Applications "$DMG_SRC/Applications"
  hdiutil create -volname "NimbusTerm $VERSION" -srcfolder "$DMG_SRC" -ov -format UDZO "$DMG" >/dev/null
fi

# ---------- PKG: Installer.app wizard ----------
PKG_ROOT="$BUILD/pkg-root"
PKG_RES="$BUILD/pkg-resources"
mkdir -p "$PKG_ROOT" "$PKG_RES"
ditto "$APP" "$PKG_ROOT/NimbusTerm.app"
xattr -cr "$PKG_ROOT/NimbusTerm.app"
cp "$BUILD/pkg-background.png" "$PKG_RES/background.png"
cp Resources/installer/welcome.html "$PKG_RES/welcome.html"
cp Resources/installer/conclusion.html "$PKG_RES/conclusion.html"
cp Resources/installer/Distribution.xml "$PKG_RES/Distribution.xml"
cp -R Resources/installer/en.lproj "$PKG_RES/en.lproj"

pkgbuild \
  --root "$PKG_ROOT" \
  --identifier com.maestro37.nimbusterm \
  --version "$VERSION" \
  --install-location /Applications \
  --ownership preserve \
  "$BUILD/NimbusTerm-component.pkg" >/dev/null

rm -f "$PKG"
productbuild \
  --distribution "$PKG_RES/Distribution.xml" \
  --resources "$PKG_RES" \
  --package-path "$BUILD" \
  "$PKG" >/dev/null

(cd dist && shasum -a 256 "NimbusTerm-$VERSION.dmg" "NimbusTerm-$VERSION.pkg" > SHA256SUMS.txt)

echo "DMG: $DMG"
echo "PKG: $PKG"
echo "SHA256: dist/SHA256SUMS.txt"
