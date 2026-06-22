#!/usr/bin/env bash
set -e

APP_NAME="SubMelon"
DEV_MODE=false
[[ "$1" == "--dev" ]] && DEV_MODE=true

# ── 依赖检查（开发模式和全量模式都需要）────────────────────────────────────
MISSING=""

# Swift 工具链
command -v swift &>/dev/null || MISSING="$MISSING\n  xcode-select --install   # Swift 工具链"

# ffmpeg（字幕提取 + 音频转换必须）
command -v ffmpeg &>/dev/null || MISSING="$MISSING\n  brew install ffmpeg      # 字幕提取 / 音频提取"

# mpv（全量打包时需要 libmpv.dylib；开发模式 fallback 到 Homebrew，也需要）
if ! find /opt/homebrew/lib /usr/local/lib -name "libmpv*.dylib" 2>/dev/null | grep -q .; then
    MISSING="$MISSING\n  brew install mpv         # 视频解码库"
fi

if [ -n "$MISSING" ]; then
    echo "❌ 缺少以下依赖，请先安装后再构建：$MISSING"
    echo ""
    exit 1
fi

# ── 可选依赖提示（缺少不影响构建，但语音转字幕功能不可用）─────────────────────
if ! command -v whisperx &>/dev/null; then
    echo -e "⚠️  未安装 whisperx（语音转字幕功能不可用）：\n  pip install whisperx"
    echo ""
fi

# ── Kill 旧进程 ─────────────────────────────────────────────────────────────
pkill -x "$APP_NAME" 2>/dev/null || true

if $DEV_MODE; then
    # ── 开发模式：swift build debug，直接运行可执行文件 ──────────────────────
    echo "🔧 开发模式构建中..."
    swift build 2>&1
    echo ""
    echo "🚀 启动 $APP_NAME ..."
    .build/debug/VideoSubtitlePlayer &
else
    # ── 全量打包：调用 make_app.sh，生成 SubMelon.app ───────────────────────
    echo "📦 全量打包中..."
    bash make_app.sh
    echo ""
    echo "🚀 启动 $APP_NAME ..."
    open SubMelon.app
fi
