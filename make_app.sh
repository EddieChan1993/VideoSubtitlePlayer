#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# make_app.sh  –  Build VideoSubtitlePlayer.app
#
# Usage:
#   ./make_app.sh              # 手动输入 Apple ID（留空跳过绑定）
#   ./make_app.sh -a           # 自动读取当前登录的 Apple ID
#   ./make_app.sh -i you@icloud.com  # 直接指定 Apple ID（非交互）
#   ./make_app.sh -h           # 显示帮助
#
# Requirements: Xcode Command Line Tools  →  xcode-select --install
#               brew install mpv ffmpeg
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BINARY="VideoSubtitlePlayer"   # Swift package target（编译产物名，不改）
APP="SubMelon"                 # .app 包名 / Dock 显示名
VERSION="1.1.0"
BUNDLE_ID="com.submelon.app"
MIN_OS="14.0"

# ── 帮助 ─────────────────────────────────────────────────────────────────────
usage() {
cat <<EOF
用法：  ./make_app.sh [选项]

选项：
  -a            自动从系统读取当前 Apple ID（iCloud 账号邮箱）
  -i <email>    手动指定 Apple ID（非交互，适合脚本调用）
  -h            显示此帮助并退出

不带任何选项时，会交互式询问是否绑定 Apple ID；直接回车跳过（开发模式）。

绑定后的 .app 只能在当前 Apple ID 登录的 Mac 上运行；
其他设备打开时会弹窗提示：请联系软件授权：wx DC_Wen
EOF
}

# ── 解析参数 ─────────────────────────────────────────────────────────────────
APPLE_ID=""
AUTO_DETECT=false

while getopts ":ai:h" opt; do
    case $opt in
        a) AUTO_DETECT=true ;;
        i) APPLE_ID="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) echo "错误：-$OPTARG 需要一个参数"; usage; exit 1 ;;
        \?) echo "错误：未知选项 -$OPTARG"; usage; exit 1 ;;
    esac
done

# ── Apple ID 决策 ─────────────────────────────────────────────────────────────
if [ -z "$APPLE_ID" ] && $AUTO_DETECT; then
    MOBILEME_PLIST="$HOME/Library/Preferences/MobileMeAccounts.plist"
    if [ -f "$MOBILEME_PLIST" ]; then
        APPLE_ID=$(/usr/libexec/PlistBuddy -c "Print :Accounts:0:AccountID" \
                       "$MOBILEME_PLIST" 2>/dev/null || true)
        APPLE_ID=$(echo "$APPLE_ID" | tr -d '[:space:]')
    fi
    if [ -z "$APPLE_ID" ]; then
        echo "⚠️   -a：未能读取 Apple ID，将以开发模式打包（不绑定）"
    else
        echo "▶  自动读取 Apple ID：$APPLE_ID"
    fi
elif [ -z "$APPLE_ID" ]; then
    echo ""
    printf "▶  绑定 Apple ID（留空跳过）：  "
    read -r APPLE_ID
    APPLE_ID=$(echo "$APPLE_ID" | tr -d '[:space:]')
fi

if [ -z "$APPLE_ID" ]; then
    echo "   未设置 Apple ID，开发模式（任意设备可运行）"
else
    echo "   绑定 Apple ID：$APPLE_ID"
fi

# ── 生成图标 ─────────────────────────────────────────────────────────────────
echo "▶  生成应用图标…"
if swift make_icon.swift; then
    if [ -d "AppIcon.iconset" ]; then
        iconutil -c icns AppIcon.iconset -o AppIcon.icns
        echo "   ✓  AppIcon.icns 已生成"
    fi
else
    echo "⚠️   图标生成失败，跳过（不影响主程序）"
fi

# ── 编译 Release ──────────────────────────────────────────────────────────────
echo "▶  编译 Release 版本…"
swift build -c release

BIN=".build/release/$BINARY"
[ -f "$BIN" ] || { echo "错误：找不到二进制文件 $BIN"; exit 1; }

# ── 组装 .app 包 ──────────────────────────────────────────────────────────────
APPDIR="${APP}.app"
CONTENTS="${APPDIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "▶  组装 ${APPDIR}…"
rm -rf "$APPDIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN" "$MACOS/$APP"   # 二进制重命名为 $APP，与 CFBundleExecutable 保持一致

if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$RESOURCES/AppIcon.icns"
    ICON_KEY='  <key>CFBundleIconFile</key>        <string>AppIcon</string>'
else
    ICON_KEY=""
fi

if [ -n "$APPLE_ID" ]; then
    APPLE_ID_KEY="  <key>BoundAppleID</key>             <string>${APPLE_ID}</string>"
else
    APPLE_ID_KEY=""
fi

# ── Info.plist ────────────────────────────────────────────────────────────────
cat > "${CONTENTS}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>${APP}</string>
  <key>CFBundleDisplayName</key>        <string>${APP}</string>
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

# ── Ad-hoc 签名 ───────────────────────────────────────────────────────────────
echo "▶  Ad-hoc 签名…"
codesign --force --deep --sign - "$APPDIR"

echo ""
echo "✅  ${APPDIR} 已就绪"
[ -n "$APPLE_ID" ] && echo "   🔒  已绑定 Apple ID：${APPLE_ID}"
echo ""
echo "   立即打开：    open '${APPDIR}'"
echo "   移动到应用：  mv '${APPDIR}' /Applications/"
echo ""
echo "   首次打开提示：右键 → 打开  （绕过 Gatekeeper）"
echo "   或执行：      xattr -rd com.apple.quarantine '${APPDIR}'"
