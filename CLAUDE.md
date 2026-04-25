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
- `prepare(url:)`：`dlopen` 加载 libmpv，初始化上下文，设置 `--vo=libmpv`（禁止创建原生窗口），调用 `setupRenderContext()`（必须在 loadfile **之前**），调用 `loadfile`，启动事件循环线程（监听 `time-pos` 属性驱动字幕同步）。
- `setupRenderContext()`：通过 `mpv_render_context_create`（SW 渲染 API）建立渲染上下文，注册新帧回调 `onNeedsDisplay`。
- `renderFrameAsCGImage(width:height:)`：在专用后台队列中调用，将当前帧写入 64 字节对齐的像素缓冲区，返回 `CGImage`，由主线程设置为 `CALayer.contents`。

**`MPVPlayerView.swift`** — `MPVHostView: NSView`：
- `wantsLayer=true`，`layer.contents` 直接接收 `CGImage`，避开 OpenGL/Metal 合成问题。
- 回调驱动渲染：`onNeedsDisplay` → `scheduleRender()` → 后台队列 `renderFrameAsCGImage` → 主线程更新 `layer.contents`。
- `setFrameSize` 覆盖（关键）：SwiftUI 通过 `setFrameSize` 设置尺寸，不触发 `layout()`，必须在此更新 `renderW/H`。

### 字幕流水线

`SubtitleExtractor` 分两阶段：
1. **立即阶段** (`extractImmediate`)：并发尝试流 0 和流 1，伴随文件（`.srt/.vtt/.ass`）优先，尽快展示第一批字幕。
2. **后台阶段** (`listTracksWithLabels`)：解析 `ffmpeg -i` 的 stderr 获取完整轨道信息（语言标签、标题），更新 picker；`preCacheOtherTracks` 后台预缓存所有轨道。

`SubtitleMode`（`single` / `bilingual`）实现了 `Hashable`，作为 `[SubtitleMode: [Subtitle]]` 缓存字典的键，切换轨道时无需重新提取。

轨道选择策略（`buildOptions()`）：只展示最多两个选项——英文单轨 + 中英双语，简洁服务语言学习场景。

### 字幕显示架构

**mpv 内置字幕渲染已禁用**（`sub-visibility=no`）。字幕完全由 SwiftUI 层负责：

- **视频浮层**（`videoSubtitleOverlay`）：ZStack 最顶层，读取 `vm.subtitles[currentSubtitleIndex].cleanText`，受 `vm.showSubtitles` 控制，切换轨道/显隐自动生效，无需与 mpv 的 `sid` 属性交互。
- **底部字幕栏**：`NavigationBarView` 中的 `subtitleLabel`，同样受 `showSubtitles` 控制。

优点：切换轨道（英文↔双语）后浮层内容自动更新；隐藏字幕时两处同步消失，不需要向 mpv 发送任何命令。

### 导航时间同步

`PlayerViewModel` 在 `syncCurrentSubtitle(at:)` 里同步更新 `currentPlaybackTime`（私有），供 `previousSubtitle` / `nextSubtitle` 在字幕间隙时定位正确位置（AVPlayer 和 MPV 统一走 `var now: TimeInterval`）。

### C ABI 说明

`MPVController` 中所有 libmpv 函数指针均通过 `sym<T>(_:)` 用 `unsafeBitCast` 从 `dlsym` 结果转换。Render API 参数结构体须手动对齐：`MPVRenderParam` 在 `type: Int32` 后有 4 字节 `_pad`，总大小 16 字节以匹配 C 端 `mpv_render_param`。字符串参数（如 `"sw"`）必须用 `withCString` 嵌套传递，避免 ARC 提前释放。

---

## 已修复的 Bug 及根本原因

### Bug 1 — 视频黑屏（只有声音，无画面）

| | |
|---|---|
| **现象** | 导入视频后音频正常播放，视频区域全黑 |
| **根本原因** | `mpv_render_context_create()` 在 `loadfile` **之后**调用。mpv 在 `loadfile` 时寻找 VO（视频输出），若此时 render context 尚未建立则直接跳过视频解码管线，后续再建立 context 也无效 |
| **修复** | 将 `setupRenderContext()` 移到 `cmd(["loadfile", ...])` 之前调用，保证 VO 初始化时 context 已就绪 |
| **文件** | `MPVController.swift` — `prepare(url:)` |

### Bug 2 — 播放/暂停、音量命令无效

| | |
|---|---|
| **现象** | 点击暂停按钮或拖动音量滑块，视频播放状态和音量均无变化 |
| **根本原因** | 使用了 `cmd(["set_property", "pause", "yes"])` — `set_property` 不是有效的 mpv 命令字符串（它是 Lua 脚本 API，不是 IPC 命令）。`mpv_command` 接受的正确命令是 `"set"` |
| **修复** | 将所有 `"set_property"` 改为 `"set"`：`cmd(["set", "pause", "yes"])` / `cmd(["set", "volume", "50"])` |
| **文件** | `MPVController.swift` — `setPlaying()`, `setVolume()` |

### Bug 3 — 键盘快捷键 A/S/D 不生效

| | |
|---|---|
| **现象** | 按 A/S/D 键无任何反应 |
| **根本原因 1** | SwiftUI 的 `.keyboardShortcut("a", modifiers: [])` 作用于零尺寸隐形 `Button` 时在 macOS 上不可靠，不能保证拦截到按键事件 |
| **根本原因 2** | `event.charactersIgnoringModifiers?.lowercased()` 依赖键盘布局和字符映射，不同输入法下可能匹配失败 |
| **修复** | 改用 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` + `event.keyCode`（A=0, S=1, D=2, Space=49），在 `ContentView.onAppear` 注册，全局生效，不受焦点和输入法影响 |
| **文件** | `ContentView.swift` — `ContentView.body.onAppear` |

### Bug 4 — 点击字幕导航后暂停按钮未同步为播放状态

| | |
|---|---|
| **现象** | 视频暂停时点击「上一条/下一条字幕」，视频恢复播放，但底部播放按钮仍显示「播放」图标（未切换为「暂停」）|
| **根本原因** | `jumpToSubtitle()` 调用了 `mpv.setPlaying(true)`（实际告知 mpv 恢复播放），但没有同步更新 `PlayerViewModel.isPlaying`，导致 SwiftUI UI 与实际状态不一致 |
| **修复** | 在 `jumpToSubtitle()` 两个分支（MPV 和 AVPlayer）中都加上 `isPlaying = true` |
| **文件** | `PlayerViewModel.swift` — `jumpToSubtitle()` |

### Bug 5 — 隐藏字幕时视频浮层仍然显示

| | |
|---|---|
| **现象** | 点击「隐藏字幕」按钮后，底部字幕栏消失，但视频画面上的字幕依然可见 |
| **根本原因** | mpv 默认自行渲染字幕并烘焙进视频帧，`showSubtitles` 状态只控制了 SwiftUI 底部栏，未影响 mpv 的渲染管线 |
| **修复** | 在 `prepare()` 中加入 `opt("no", "sub-visibility")`，完全禁用 mpv 内置字幕渲染；改为在视频 ZStack 顶层添加 SwiftUI `videoSubtitleOverlay`，统一由 `vm.showSubtitles` + `vm.currentSubtitleIndex` 驱动，切轨和显隐均自动同步 |
| **文件** | `MPVController.swift` — `prepare()`；`ContentView.swift` — `videoSubtitleOverlay` |

### 规律总结

1. **mpv 初始化顺序严格**：render context 必须在 `loadfile` 之前创建，否则 VO 初始化失败且不可恢复。
2. **mpv 命令字符串**：通过 `mpv_command` 发送的命令用 `"set"` 设置属性，`"set_property"` 是 Lua API，二者不可混用。
3. **macOS 键盘拦截**：SwiftUI `.keyboardShortcut` 对无修饰键的单字母快捷键不可靠；`NSEvent.addLocalMonitorForEvents` + `keyCode` 是唯一可靠方案。
4. **UI 状态与后端状态同步**：凡是通过 mpv 命令改变播放状态的地方，必须同时更新 `@Published` 变量，否则 SwiftUI 视图与实际状态会漂移。
5. **字幕渲染归属**：若需要在 SwiftUI 层控制字幕（显隐/切轨），必须禁用 mpv 的内置渲染，否则无法统一管理两套显示系统。
