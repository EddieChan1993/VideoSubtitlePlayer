#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# make_app.sh  –  Build VideoSubtitlePlayer.app
#
# Usage:
#   chmod +x make_app.sh
#   ./make_app.sh
#
# Requirements: Xcode Command Line Tools (xcode-select --install)
#               brew install mpv ffmpeg
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APP="VideoSubtitlePlayer"
VERSION="1.1.0"
BUNDLE_ID="com.videosubtitleplayer.app"
MIN_OS="14.0"

# ── 1. Apple ID binding ──────────────────────────────────────────────────────
#
# Default  : prompt for manual input (Enter = skip binding / dev mode)
# --auto   : auto-detect from ~/Library/Preferences/MobileMeAccounts.plist
# --apple-id <email> : use the given email directly (non-interactive)
#
APPLE_ID=""
AUTO_DETECT=false

for arg in "$@"; do
    case "$arg" in
        --auto) AUTO_DETECT=true ;;
    esac
done

# Handle --apple-id <email>
i=1
while [ $i -le $# ]; do
    eval "arg=\${$i}"
    if [ "$arg" = "--apple-id" ]; then
        j=$((i+1))
        eval "APPLE_ID=\${$j}"
        break
    fi
    i=$((i+1))
done

if [ -z "$APPLE_ID" ] && $AUTO_DETECT; then
    MOBILEME_PLIST="$HOME/Library/Preferences/MobileMeAccounts.plist"
    if [ -f "$MOBILEME_PLIST" ]; then
        APPLE_ID=$(/usr/libexec/PlistBuddy -c "Print :Accounts:0:AccountID" \
                       "$MOBILEME_PLIST" 2>/dev/null || true)
    fi
    if [ -z "$APPLE_ID" ]; then
        echo "⚠️   --auto: could not detect Apple ID — app will run on any machine."
    else
        echo "▶  Auto-detected Apple ID: $APPLE_ID"
    fi
elif [ -z "$APPLE_ID" ]; then
    echo ""
    printf "▶  Enter Apple ID to bind (leave empty to skip): "
    read -r APPLE_ID
    APPLE_ID=$(echo "$APPLE_ID" | tr -d '[:space:]')
fi

if [ -z "$APPLE_ID" ]; then
    echo "   No Apple ID set — app will run on any machine (dev mode)."
else
    echo "   Binding to Apple ID: $APPLE_ID"
fi

# ── 2. Generate app icon ─────────────────────────────────────────────────────
echo "▶  Generating app icon…"
if swift make_icon.swift; then
    if [ -d "AppIcon.iconset" ]; then
        iconutil -c icns AppIcon.iconset -o AppIcon.icns
        echo "   ✓  AppIcon.icns created"
    fi
else
    echo "⚠️   Icon generation failed — continuing without custom icon"
fi

# ── 3. Build release binary ──────────────────────────────────────────────────
echo "▶  Building release binary…"
swift build -c release

BIN=".build/release/$APP"
if [ ! -f "$BIN" ]; then
  echo "Error: binary not found at $BIN"; exit 1
fi

# ── 4. Assemble .app bundle ──────────────────────────────────────────────────
APPDIR="${APP}.app"
CONTENTS="${APPDIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "▶  Assembling ${APPDIR}…"
rm -rf "$APPDIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN" "$MACOS/$APP"

# Copy icon if it was generated
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$RESOURCES/AppIcon.icns"
    ICON_KEY='  <key>CFBundleIconFile</key>        <string>AppIcon</string>'
else
    ICON_KEY=""
fi

# ── 5. Write Info.plist (with optional BoundAppleID) ─────────────────────────
if [ -n "$APPLE_ID" ]; then
    APPLE_ID_KEY="  <key>BoundAppleID</key>             <string>${APPLE_ID}</string>"
else
    APPLE_ID_KEY=""
fi

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
${ICON_KEY}
${APPLE_ID_KEY}
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

# ── 6. Ad-hoc codesign ───────────────────────────────────────────────────────
echo "▶  Signing (ad-hoc)…"
codesign --force --deep --sign - "$APPDIR"

echo ""
echo "✅  ${APPDIR} is ready."
if [ -n "$APPLE_ID" ]; then
    echo "   🔒  Bound to Apple ID: ${APPLE_ID}"
fi
echo ""
echo "   Open now:          open '${APPDIR}'"
echo "   Move to /Applications:"
echo "                      mv '${APPDIR}' /Applications/"
echo ""
echo "   First launch on a new machine: right-click → Open  (Gatekeeper bypass)"
echo "   Or strip quarantine:  xattr -rd com.apple.quarantine '${APPDIR}'"
