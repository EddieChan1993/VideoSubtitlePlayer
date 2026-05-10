#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# make_app.sh  –  Build SubMelon.app（含 libmpv + ffmpeg，即开即用）
#
# 单个用户：
#   ./make_app.sh -i user@icloud.com
#
# 批量打包（多个 Apple ID）：
#   ./make_app.sh -i user1@icloud.com,user2@163.com,user3@qq.com
#   ./make_app.sh -l ids.txt          # 文件，每行一个 Apple ID
#
# 其他选项：
#   ./make_app.sh -a                  # 自动读取当前登录 Apple ID
#   ./make_app.sh                     # 不绑定，生成 SubMelon.app（任意设备可用）
#   ./make_app.sh -h                  # 显示帮助
#
# 构建机要求：
#   xcode-select --install
#   brew install mpv ffmpeg
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BINARY="VideoSubtitlePlayer"
APP="SubMelon"
VERSION="1.1.0"
BUNDLE_ID="com.submelon.app"
MIN_OS="13.0"

# ── 帮助 ─────────────────────────────────────────────────────────────────────
usage() {
cat <<EOF
用法：  ./make_app.sh [选项]

  -i <id[,id2,...]>  指定一个或多个 Apple ID（逗号分隔）
  -l <file>          从文件读取 Apple ID 列表（每行一个）
  -a                 自动读取当前登录 Apple ID
  -h                 显示帮助

不带任何选项时，打包不绑定版本（SubMelon.app，任意设备可运行）。
绑定后的 .app 只能在对应 Apple ID 登录的 Mac 上运行。
EOF
}

# ── 解析参数 ─────────────────────────────────────────────────────────────────
RAW_IDS=""
ID_FILE=""
AUTO_DETECT=false

while getopts ":i:l:ah" opt; do
    case $opt in
        i) RAW_IDS="$OPTARG" ;;
        l) ID_FILE="$OPTARG" ;;
        a) AUTO_DETECT=true ;;
        h) usage; exit 0 ;;
        :) echo "错误：-$OPTARG 需要一个参数"; usage; exit 1 ;;
        \?) echo "错误：未知选项 -$OPTARG"; usage; exit 1 ;;
    esac
done

# ── 收集所有 Apple ID ─────────────────────────────────────────────────────────
APPLE_IDS=()

if $AUTO_DETECT; then
    MOBILEME_PLIST="$HOME/Library/Preferences/MobileMeAccounts.plist"
    if [ -f "$MOBILEME_PLIST" ]; then
        AUTO_ID=$(/usr/libexec/PlistBuddy -c "Print :Accounts:0:AccountID" \
                      "$MOBILEME_PLIST" 2>/dev/null | tr -d '[:space:]' || true)
        [ -n "$AUTO_ID" ] && APPLE_IDS+=("$AUTO_ID")
    fi
    [ ${#APPLE_IDS[@]} -eq 0 ] && echo "⚠️   未能读取 Apple ID，将以开发模式打包"
fi

if [ -n "$RAW_IDS" ]; then
    IFS=',' read -ra IDS_ARR <<< "$RAW_IDS"
    for id in "${IDS_ARR[@]}"; do
        id=$(echo "$id" | tr -d '[:space:]')
        [ -n "$id" ] && APPLE_IDS+=("$id")
    done
fi

if [ -n "$ID_FILE" ]; then
    [ -f "$ID_FILE" ] || { echo "错误：找不到文件 $ID_FILE"; exit 1; }
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '[:space:]')
        [ -n "$line" ] && APPLE_IDS+=("$line")
    done < "$ID_FILE"
fi

if [ ${#APPLE_IDS[@]} -eq 0 ]; then
    echo "   未设置 Apple ID，打包开发版（任意设备可运行）"
    APPLE_IDS=("")   # 空字符串 = 不绑定
else
    echo "   将为 ${#APPLE_IDS[@]} 个 Apple ID 打包：${APPLE_IDS[*]}"
fi

# ── 生成图标 ─────────────────────────────────────────────────────────────────
echo "▶  生成应用图标…"
if swift make_icon.swift; then
    [ -d "AppIcon.iconset" ] && iconutil -c icns AppIcon.iconset -o AppIcon.icns
    echo "   ✓  AppIcon.icns 已生成"
else
    echo "⚠️   图标生成失败，跳过"
fi

# ── 编译 Release ──────────────────────────────────────────────────────────────
echo "▶  编译 Release 版本…"
swift build -c release
BIN=".build/release/$BINARY"
[ -f "$BIN" ] || { echo "错误：找不到 $BIN"; exit 1; }

# ── 构建暂存目录（编译 + 依赖只做一次）───────────────────────────────────────
STAGING=".build/__staging__"
STAGING_CONTENTS="$STAGING/Contents"
STAGING_MACOS="$STAGING_CONTENTS/MacOS"
STAGING_RESOURCES="$STAGING_CONTENTS/Resources"
STAGING_FRAMEWORKS="$STAGING_CONTENTS/Frameworks"

echo "▶  组装暂存包…"
rm -rf "$STAGING"
mkdir -p "$STAGING_MACOS" "$STAGING_RESOURCES" "$STAGING_FRAMEWORKS"
cp "$BIN" "$STAGING_MACOS/$APP"
[ -f "AppIcon.icns" ] && cp AppIcon.icns "$STAGING_RESOURCES/AppIcon.icns"

# ── 打包依赖库 ────────────────────────────────────────────────────────────────
bundle_dylib() {
    local src="$1"
    [ -f "$src" ] || return 0
    local name; name=$(basename "$src")
    local dst="$STAGING_FRAMEWORKS/$name"
    [ -f "$dst" ] && return 0

    cp "$src" "$dst"
    chmod 644 "$dst"
    install_name_tool -id "@executable_path/../Frameworks/$name" "$dst" 2>/dev/null || true

    otool -L "$src" 2>/dev/null \
        | awk 'NR>1{print $1}' \
        | grep -E "^(/opt/homebrew|/usr/local)" \
        | while IFS= read -r dep; do
            dep_name=$(basename "$dep")
            install_name_tool -change "$dep" \
                "@executable_path/../Frameworks/$dep_name" "$dst" 2>/dev/null || true
            bundle_dylib "$dep"
        done
}

echo "▶  打包 libmpv…"
LIBMPV_SRC=$(find /opt/homebrew/lib /usr/local/lib \
    \( -name "libmpv.dylib" -o -name "libmpv.*.dylib" \) 2>/dev/null \
    | grep -v '@' | sort | head -1 || true)
if [ -n "$LIBMPV_SRC" ]; then
    bundle_dylib "$LIBMPV_SRC"
    LIBMPV_NAME=$(basename "$LIBMPV_SRC")
    [ "$LIBMPV_NAME" != "libmpv.dylib" ] && [ ! -f "$STAGING_FRAMEWORKS/libmpv.dylib" ] && \
        ln -sf "$LIBMPV_NAME" "$STAGING_FRAMEWORKS/libmpv.dylib"
    echo "   ✓  libmpv 已打包"
else
    echo "⚠️   未找到 libmpv（brew install mpv）"
fi

echo "▶  打包 ffmpeg…"
FFMPEG_SRC=$(command -v ffmpeg 2>/dev/null || true)
if [ -n "$FFMPEG_SRC" ]; then
    cp "$FFMPEG_SRC" "$STAGING_MACOS/ffmpeg"
    chmod +x "$STAGING_MACOS/ffmpeg"
    otool -L "$FFMPEG_SRC" 2>/dev/null \
        | awk 'NR>1{print $1}' \
        | grep -E "^(/opt/homebrew|/usr/local)" \
        | while IFS= read -r dep; do
            dep_name=$(basename "$dep")
            install_name_tool -change "$dep" \
                "@executable_path/../Frameworks/$dep_name" "$STAGING_MACOS/ffmpeg" 2>/dev/null || true
            bundle_dylib "$dep"
        done
    echo "   ✓  ffmpeg 已打包"
else
    echo "⚠️   未找到 ffmpeg（brew install ffmpeg）"
fi

# ── 为每个 Apple ID 生成 .app ─────────────────────────────────────────────────
ICON_KEY=""
[ -f "AppIcon.icns" ] && ICON_KEY='  <key>CFBundleIconFile</key>        <string>AppIcon</string>'

BUILT_APPS=()

for APPLE_ID in "${APPLE_IDS[@]}"; do
    if [ -n "$APPLE_ID" ]; then
        PREFIX="${APPLE_ID%%@*}"
        APPDIR="${APP}-${PREFIX}.app"
        APPLE_ID_KEY="  <key>BoundAppleID</key>             <string>${APPLE_ID}</string>"
    else
        APPDIR="${APP}.app"
        APPLE_ID_KEY=""
    fi

    echo "▶  打包 ${APPDIR}…"
    rm -rf "$APPDIR"
    cp -r "$STAGING" "$APPDIR"

    # 写入 Info.plist（唯一因 Apple ID 不同而变化的部分）
    cat > "${APPDIR}/Contents/Info.plist" << PLIST
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

    # 签名：先签 dylib，再签整体
    find "${APPDIR}/Contents/Frameworks" \( -name "*.dylib" -o -name "*.so" \) \
        -exec codesign --force --sign - {} \; 2>/dev/null || true
    [ -f "${APPDIR}/Contents/MacOS/ffmpeg" ] && \
        codesign --force --sign - "${APPDIR}/Contents/MacOS/ffmpeg" 2>/dev/null || true
    codesign --force --deep --sign - "$APPDIR"

    BUILT_APPS+=("$APPDIR")
    echo "   ✓  ${APPDIR}"
done

# ── 清理暂存 ──────────────────────────────────────────────────────────────────
rm -rf "$STAGING"

# ── 为每个 .app 生成「首次打开.command」启动器 ────────────────────────────────
for _app in "${BUILT_APPS[@]}"; do
    _launcher="${_app%.app}-首次打开.command"
    sed "s|__APP__|${_app}|g" > "$_launcher" << 'LAUNCHER_SCRIPT'
#!/usr/bin/env bash
cd "$(dirname "$0")"
APP="__APP__"
xattr -rd com.apple.quarantine "$APP" 2>/dev/null
open "$APP"
osascript -e 'tell application "Terminal" to close front window' 2>/dev/null
exit 0
LAUNCHER_SCRIPT
    chmod +x "$_launcher"
done

# ── 完成汇总 ──────────────────────────────────────────────────────────────────
echo ""
echo "✅  打包完成，共 ${#BUILT_APPS[@]} 个："
for _app in "${BUILT_APPS[@]}"; do
    echo "   • ${_app}"
    echo "     └ ${_app%.app}-首次打开.command"
done
echo ""
echo "   将 .app 和对应的 -首次打开.command 一起发给对方，对方双击 .command 首次打开即可。"
