# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 构建与运行

```bash
swift build                        # 编译
swift run                          # 编译并运行
swift build 2>&1 | grep -E "error:|Build complete"   # 只看错误/结果
```

无 Xcode 工程，无沙盒限制，以 `swift run` 方式运行。macOS 14+ 目标平台，需要链接 OpenGL 框架（已在 Package.swift 中配置）。

## 依赖

- **libmpv**（Homebrew）：`brew install mpv`，安装路径 `/opt/homebrew/lib/libmpv.dylib`，通过 `dlopen` 运行时加载，无编译期链接。
- **FFmpeg**（Homebrew）：`brew install ffmpeg`，用于字幕提取，路径 `/opt/homebrew/bin/ffmpeg`。
- 两者均为可选依赖，缺失时有降级路径。

## 架构概览

### 视频播放策略（三层降级）

`PlayerViewModel.playDirectly(url:)` 按顺序尝试：

1. **MPV 路径**（首选）：检测到 libmpv.dylib → 调用 `switchToMPV`，设置 `useMPV=true`、`isVideoLoaded=true`，创建 `MPVController` 并调用 `prepare(url:)`。
2. **AVFoundation**（降级）：libmpv 不可用时用 `AVPlayer`，若 `AVPlayerItem.status == .failed` 进入第 3 步。
3. **FragStreamer**（最终降级）：调用 FFmpeg 将视频转为分片 MP4（`frag_keyframe+empty_moov`），写入临时文件后交给 `AVPlayer` 播放。

### MPV 嵌入实现

核心挑战：macOS 上 `--wid` 在任何进程模式下均无法将 mpv 嵌入宿主 NSView；必须使用 **mpv Render API**。

**`MPVController.swift`** — 三步式生命周期：
- `prepare(url:)`：`dlopen` 加载 libmpv，初始化上下文，设置 `--vo=libmpv`（禁止创建原生窗口），调用 `loadfile`，启动事件循环线程（监听 `time-pos` 属性驱动字幕同步）。
- `setupRenderContext()`：当 OpenGL 上下文就绪时由视图层调用，通过 `mpv_render_context_create` 建立渲染上下文，注册新帧回调 `onNeedsDisplay`。
- `renderFrame(width:height:)`：在 display link 回调中调用，将当前帧渲染到 FBO 0。

**`MPVPlayerView.swift`** — `MPVHostView: NSView`：
- 手动创建 `NSOpenGLContext`（双缓冲），设 `wantsLayer=true`，在 `viewDidMoveToWindow` 里绑定 `glCtx.view = self`，调用 `setupRenderContext()`。
- 用 `CVDisplayLink`（文件级 `@convention(c)` 回调 `mpvDisplayLinkOutput`）驱动渲染，每帧调用 `drawFrame()` → 加锁 → `renderFrame` → `CGLFlushDrawable`。
- 注意：`CAOpenGLLayer` 在 SwiftUI/Metal 层树中无法被可靠驱动，故采用普通 NSView + 手动 GL 上下文方案。

### 字幕流水线

`SubtitleExtractor` 分两阶段：
1. **立即阶段** (`extractImmediate`)：并发尝试流 0 和流 1，伴随文件（`.srt/.vtt/.ass`）优先，尽快展示第一批字幕。
2. **后台阶段** (`listTracksWithLabels`)：解析 `ffmpeg -i` 的 stderr 获取完整轨道信息（语言标签、标题），更新 picker；`preCacheOtherTracks` 后台预缓存所有轨道。

`SubtitleMode`（`single` / `bilingual`）实现了 `Hashable`，作为 `[SubtitleMode: [Subtitle]]` 缓存字典的键，切换轨道时无需重新提取。

### 导航时间同步

`PlayerViewModel` 在 `syncCurrentSubtitle(at:)` 里同步更新 `currentPlaybackTime`（私有），供 `previousSubtitle` / `nextSubtitle` 在字幕间隙时定位正确位置（AVPlayer 和 MPV 统一走 `var now: TimeInterval`）。

### C ABI 说明

`MPVController` 中所有 libmpv 函数指针均通过 `sym<T>(_:)` 用 `unsafeBitCast` 从 `dlsym` 结果转换。Render API 参数结构体须手动对齐：`MPVRenderParam` 在 `type: Int32` 后有 4 字节 `_pad`，总大小 16 字节以匹配 C 端 `mpv_render_param`。字符串参数（如 `"opengl"`）必须用 `withCString` 嵌套传递，避免 ARC 提前释放。
