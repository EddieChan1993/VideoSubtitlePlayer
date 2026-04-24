# VideoSubtitlePlayer

macOS 视频字幕播放器。加载视频后自动提取内嵌字幕，支持点击字幕跳转播放、三键导航（上一条 / 重播当前 / 下一条），双语字幕合并显示。

## 特性

- 支持 MKV、MP4、MOV、AVI 等主流格式（通过 libmpv 播放，无格式限制）
- 自动提取内嵌字幕轨道（SRT / VTT / ASS/SSA），也支持同名伴随字幕文件
- 多轨道切换 + 双语模式（中英自动配对）
- 字幕列表实时高亮当前播放条目，点击任意字幕即跳转
- 字幕缓存：首次提取后切换轨道无需等待
- 无 Xcode 沙盒限制，`swift run` 直接运行

## 安装依赖

```bash
brew install mpv ffmpeg
```

## 运行

```bash
git clone https://github.com/EddieChan1993/VideoSubtitlePlayer.git
cd VideoSubtitlePlayer
swift run
```

## 使用方式

1. 拖入视频文件，或点击「选择视频…」/ 菜单 ⌘O
2. 字幕自动提取并在右侧列表显示
3. 点击任意字幕条目跳转到该位置播放
4. 底部三个按钮：⏮ 上一条 · ↺ 重播当前 · ⏭ 下一条
5. 多字幕轨道时顶部出现轨道选择器，支持单轨或双语模式

## 系统要求

- macOS 14 (Sonoma) 或更高
- Homebrew 安装的 mpv（libmpv.dylib）和 FFmpeg

## 技术说明

视频渲染使用 libmpv Render API（`mpv_render_context_create`），通过 `NSOpenGLContext` + `CVDisplayLink` 将画面嵌入应用窗口，不会弹出独立的 mpv 窗口。字幕提取通过 FFmpeg 子进程完成，stderr 重定向到 `/dev/null` 避免管道死锁。
