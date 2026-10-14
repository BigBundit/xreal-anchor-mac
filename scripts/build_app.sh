#!/bin/bash
# Builds XREAL Anchor.app into ./dist.
#   --install  also copy it to /Applications and relaunch it from there
#   --release  also make an ad-hoc signed zip in ./dist for publishing
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/XREAL Anchor.app"
VERSION="1.0.0"
if [ "${1:-}" = "--release" ]; then
  # Universal binary so the download works on Apple Silicon and Intel Macs.
  swift build -c release --arch arm64 --arch x86_64 --product XrealAnchor
  BIN=".build/out/Products/Release/XrealAnchor"
  [ -f "$BIN" ] || BIN=".build/apple/Products/Release/XrealAnchor"
else
  swift build -c release --product XrealAnchor
  BIN=".build/release/XrealAnchor"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/XrealAnchor"

# Icon
ICONSET=.build/AppIcon.iconset
if [ ! -f .build/AppIcon.icns ] || [ scripts/make_icon.swift -nt .build/AppIcon.icns ]; then
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift scripts/make_icon.swift .build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s .build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) .build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o .build/AppIcon.icns
fi
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>XREAL Anchor</string>
  <key>CFBundleDisplayName</key><string>XREAL Anchor</string>
  <key>CFBundleIdentifier</key><string>com.big.xreal-anchor</string>
  <key>CFBundleExecutable</key><string>XrealAnchor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign with the local self-signed identity when present so macOS privacy permissions
# survive rebuilds; fall back to ad-hoc signing otherwise.
IDENTITY="XREAL Anchor Local Signing"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --deep --sign "$IDENTITY" --identifier com.big.xreal-anchor "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "Built: $APP"

if [ "${1:-}" = "--install" ]; then
  DEST="/Applications/XREAL Anchor.app"
  pkill -x XrealAnchor 2>/dev/null && sleep 2 || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  # Make Finder/Dock pick up the new icon.
  touch "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  open "$DEST"
  echo "Installed: $DEST"
fi

if [ "${1:-}" = "--release" ]; then
  # Re-sign ad hoc: a local self-signed certificate means nothing on other Macs.
  STAGE="$(mktemp -d)"
  ditto "$APP" "$STAGE/XREAL Anchor.app"
  codesign --force --deep --sign - --identifier com.big.xreal-anchor "$STAGE/XREAL Anchor.app"
  ZIP="dist/XREAL-Anchor-$VERSION-macOS.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$STAGE/XREAL Anchor.app" "$ZIP"
  rm -rf "$STAGE"
  echo "Release: $ZIP"
fi
