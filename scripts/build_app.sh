#!/bin/zsh
# Builds "Claudeck.app" (and a .dmg) into ./dist.  Pass --install to copy it into /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Claudeck"
# Kept from when the app was called Claude Deck, so settings carry over.
BUNDLE_ID="com.ferrousdesigner.claudedeck"
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "▸ Building release binary (v$VERSION, build $BUILD)"
swift build -c release --arch arm64 --arch x86_64 2>/dev/null || swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path 2>/dev/null)
[[ -f .build/apple/Products/Release/Claudeck ]] && BIN_DIR=.build/apple/Products/Release

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Claudeck" "$APP/Contents/MacOS/Claudeck"

echo "▸ Rendering icon"
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
swift scripts/make_icon.swift "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z $d $d "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Claudeck</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "▸ Creating DMG"
DMG="$DIST/$APP_NAME.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [[ "${1:-}" == "--install" ]]; then
  echo "▸ Installing to /Applications"
  pkill -x Claudeck 2>/dev/null || true
  # Remove the app from before it was renamed to Claudeck.
  pkill -x ClaudeDeck 2>/dev/null || true
  rm -rf "/Applications/Claude Deck.app"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  echo "✓ Installed /Applications/$APP_NAME.app"
fi

echo "✓ Built $APP and $DMG"
