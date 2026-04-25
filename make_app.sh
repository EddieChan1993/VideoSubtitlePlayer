#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# make_app.sh  –  Build VideoSubtitlePlayer.app
#
# Usage:
#   chmod +x make_app.sh
#   ./make_app.sh
#
# Requirements: Xcode Command Line Tools (xcode-select --install)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APP="VideoSubtitlePlayer"
VERSION="1.1.0"
BUNDLE_ID="com.videosubtitleplayer.app"
MIN_OS="14.0"

echo "▶  Building release binary…"
swift build -c release

BIN=".build/release/$APP"
if [ ! -f "$BIN" ]; then
  echo "Error: binary not found at $BIN"; exit 1
fi

APPDIR="${APP}.app"
CONTENTS="${APPDIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "▶  Assembling ${APPDIR}…"
rm -rf "$APPDIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN" "$MACOS/$APP"

cat > "${CONTENTS}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>${APP}</string>
  <key>CFBundleDisplayName</key>        <string>Video Subtitle Player</string>
  <key>CFBundleIdentifier</key>         <string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key>            <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleExecutable</key>         <string>${APP}</string>
  <key>NSPrincipalClass</key>           <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>    <true/>
  <key>LSMinimumSystemVersion</key>     <string>${MIN_OS}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>mkv</string>  <string>mp4</string>  <string>mov</string>
        <string>avi</string>  <string>m4v</string>  <string>wmv</string>
        <string>flv</string>  <string>webm</string> <string>ts</string>
      </array>
      <key>CFBundleTypeName</key>  <string>Video File</string>
      <key>CFBundleTypeRole</key>  <string>Viewer</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "▶  Signing (ad-hoc)…"
codesign --force --deep --sign - "$APPDIR"

echo ""
echo "✅  ${APPDIR} is ready."
echo ""
echo "   Open now:          open '${APPDIR}'"
echo "   Move to /Applications:"
echo "                      mv '${APPDIR}' /Applications/"
echo ""
echo "   First launch on a new machine: right-click → Open  (Gatekeeper bypass)"
echo "   Or strip quarantine:  xattr -rd com.apple.quarantine '${APPDIR}'"
