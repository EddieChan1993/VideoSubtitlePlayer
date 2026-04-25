#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# make_app.sh  –  Build SubMelon.app（含 libmpv + ffmpeg，即开即用）
#
# Usage:
#   ./make_app.sh              # 手动输入 Apple ID（留空跳过绑定）
#   ./make_app.sh -a           # 自动读取当前登录的 Apple ID
#   ./make_app.sh -i you@icloud.com  # 直接指定 Apple ID（非交互）
#   ./make_app.sh -h           # 显示帮助
#
# 构建机要求：
#   xcode-select --install
#   brew install mpv ffmpeg
# 发布后接收方无需安装任何依赖，直接双击运行。
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

# ── 组装 .app 包骨架 ──────────────────────────────────────────────────────────
APPDIR="${APP}.app"
CONTENTS="${APPDIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
FRAMEWORKS="${CONTENTS}/Frameworks"

echo "▶  组装 ${APPDIR}…"
rm -rf "$APPDIR"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"
cp "$BIN" "$MACOS/$APP"   # 二进制重命名为 $APP，与 CFBundleExecutable 一致

# ── 打包依赖库（dylib 递归复制 + 路径修正）───────────────────────────────────
#
# bundle_dylib <src_path>
#   将 src 复制到 Contents/Frameworks/，修改其 install name，
#   并递归处理所有 Homebrew 依赖链。
#   使用 process substitution 而非管道，确保递归调用在同一 shell 进程内
#   （管道右侧在子 shell 中，文件系统写入可见但函数递归调用可能丢失）。
#
bundle_dylib() {
    local src="$1"
    [ -f "$src" ] || return 0
    local name; name=$(basename "$src")
    local dst="$FRAMEWORKS/$name"
    [ -f "$dst" ] && return 0   # 已复制，跳过（防止循环依赖死循环）

    cp "$src" "$dst"
    chmod 644 "$dst"
    # 重写 dylib 自身的 install name → @executable_path/../Frameworks/<name>
    install_name_tool -id "@executable_path/../Frameworks/$name" "$dst" 2>/dev/null || true

    # 逐条修改 Homebrew 依赖引用，并递归复制该依赖
    while IFS= read -r dep; do
        local dep_name; dep_name=$(basename "$dep")
        install_name_tool -change "$dep" \
            "@executable_path/../Frameworks/$dep_name" "$dst" 2>/dev/null || true
        bundle_dylib "$dep"
    done < <(otool -L "$src" 2>/dev/null \
               | awk 'NR>1{print $1}' \
               | grep -E "^(/opt/homebrew|/usr/local)")
}

# ── 打包 libmpv ───────────────────────────────────────────────────────────────
echo "▶  打包 libmpv…"
LIBMPV_SRC=$(find /opt/homebrew/lib /usr/local/lib \
    \( -name "libmpv.dylib" -o -name "libmpv.*.dylib" \) 2>/dev/null \
    | grep -v '@' | sort | head -1 || true)

if [ -n "$LIBMPV_SRC" ]; then
    bundle_dylib "$LIBMPV_SRC"
    # 版本号命名（如 libmpv.2.dylib）时补一个无版本号的符号链接供 dlopen 使用
    LIBMPV_NAME=$(basename "$LIBMPV_SRC")
    if [ "$LIBMPV_NAME" != "libmpv.dylib" ] && [ ! -f "$FRAMEWORKS/libmpv.dylib" ]; then
        ln -sf "$LIBMPV_NAME" "$FRAMEWORKS/libmpv.dylib"
    fi
    echo "   ✓  libmpv 及依赖已打包"
else
    echo "⚠️   未找到 libmpv（brew install mpv），视频解码将降级为 AVFoundation"
fi

# ── 打包 ffmpeg ───────────────────────────────────────────────────────────────
echo "▶  打包 ffmpeg…"
FFMPEG_SRC=$(command -v ffmpeg 2>/dev/null || true)

if [ -n "$FFMPEG_SRC" ]; then
    cp "$FFMPEG_SRC" "$MACOS/ffmpeg"
    chmod +x "$MACOS/ffmpeg"
    # 修复 ffmpeg 对 Homebrew dylib 的引用
    while IFS= read -r dep; do
        dep_name=$(basename "$dep")
        install_name_tool -change "$dep" \
            "@executable_path/../Frameworks/$dep_name" "$MACOS/ffmpeg" 2>/dev/null || true
        bundle_dylib "$dep"
    done < <(otool -L "$FFMPEG_SRC" 2>/dev/null \
               | awk 'NR>1{print $1}' \
               | grep -E "^(/opt/homebrew|/usr/local)")
    echo "   ✓  ffmpeg 及依赖已打包"
else
    echo "⚠️   未找到 ffmpeg（brew install ffmpeg），字幕提取将不可用"
fi

# ── 图标 & Info.plist ─────────────────────────────────────────────────────────
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

# ── 签名（先签各 dylib，再签整个 .app）───────────────────────────────────────
echo "▶  签名…"
# 逐个签 Frameworks 内的 dylib（install_name_tool 修改后需重新签名）
find "$FRAMEWORKS" \( -name "*.dylib" -o -name "*.so" \) \
    -exec codesign --force --sign - {} \; 2>/dev/null || true
# 签 ffmpeg 可执行文件
[ -f "$MACOS/ffmpeg" ] && codesign --force --sign - "$MACOS/ffmpeg" 2>/dev/null || true
# 最后签整个 .app
codesign --force --deep --sign - "$APPDIR"

# ── 完成 ─────────────────────────────────────────────────────────────────────
echo ""
echo "✅  ${APPDIR} 已就绪（内含 libmpv + ffmpeg，即开即用）"
[ -n "$APPLE_ID" ] && echo "   🔒  已绑定 Apple ID：${APPLE_ID}"
echo ""
echo "   立即打开：    open '${APPDIR}'"
echo "   移动到应用：  mv '${APPDIR}' /Applications/"
echo ""
echo "   首次打开提示：右键 → 打开  （绕过 Gatekeeper）"
echo "   或执行：      xattr -rd com.apple.quarantine '${APPDIR}'"
