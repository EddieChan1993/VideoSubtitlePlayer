#!/usr/bin/env bash
set -e

APP_NAME="SubMelon"
DEV_MODE=false
[[ "$1" == "--dev" ]] && DEV_MODE=true

# 1. Kill 旧进程
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
