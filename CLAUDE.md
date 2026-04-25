# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 构建与运行

```bash
swift build                        # 编译
swift run                          # 编译并运行
swift build 2>&1 | grep -E "error:|Build complete"   # 只看错误/结果
```

无 Xcode 工程，无沙盒限制，以 `swift run` 方式运行。macOS 14+ 目标平台。

## 打包为 .app

```bash
./make_app.sh          # 交互询问 Apple ID（回车跳过）
./make_app.sh -a       # 自动读取当前登录 Apple ID 绑定
./make_app.sh -i x@y   # 直接指定 Apple ID
./make_app.sh -h       # 帮助
```

## 依赖

- **libmpv**（Homebrew）：`brew install mpv`，路径 `/opt/homebrew/lib/libmpv.dylib`，通过 `dlopen` 运行时加载，无编译期链接。
- **FFmpeg**（Homebrew）：`brew install ffmpeg`，路径 `/opt/homebrew/bin/ffmpeg`，用于字幕提取。
- 两者均为可选依赖，缺失时有降级路径。

---

## 架构概览

### 应用生命周期

`PlayerViewModel` 创建在 `App` 级别（`VideoSubtitleApp` 的 `@StateObject`），通过 `.environmentObject()` 传给 `ContentView`。  
**不要**将 VM 放在 `ContentView` 的 `@StateObject`——这样关窗口会销毁 VM，再开窗口时视频状态丢失，且 mpv 仍在后台播放。

```
VideoSubtitleApp (@StateObject PlayerViewModel)
  └── ContentView (@EnvironmentObject PlayerViewModel)
        ├── MPVPlayerView  → MPVHostView.viewDidMoveToWindow 重连 onNeedsDisplay
        ├── SubtitleListView
        └── NavigationBarView
```

### 视频播放策略（三层降级）

`PlayerViewModel.playDirectly(url:)` 按顺序尝试：

1. **MPV 路径**（首选）：检测到 libmpv.dylib → `switchToMPV`，`useMPV=true`，`MPVController.prepare(url:)`。
2. **AVFoundation**（降级）：libmpv 不可用时用 `AVPlayer`；`AVPlayerItem.status == .failed` 进入第 3 步。
3. **FragStreamer**（最终降级）：FFmpeg 将视频转为分片 MP4（`frag_keyframe+empty_moov`），写临时文件后交给 `AVPlayer`。

### MPV 嵌入实现

核心挑战：macOS 上 `--wid` 无法嵌入宿主 NSView，必须使用 **mpv Render API**（SW 模式）。

**`MPVController.swift`** 三步生命周期：
- `prepare(url:)`：`dlopen` 加载 libmpv → 设置选项（`--vo=libmpv`、`sub-visibility=no`）→ `setupRenderContext()` → `loadfile` → 启动事件循环线程。
- `setupRenderContext()`：`mpv_render_context_create("sw")` 建立渲染上下文，注册 `onNeedsDisplay` 回调。
- `renderFrameAsCGImage(width:height:)`：后台队列调用，64 字节对齐像素缓冲区持久复用，`CFDataCreate` 单次 memcpy 生成 `CGImage`，主线程写入 `CALayer.contents`。

**`MPVPlayerView.swift`** — `MPVHostView: NSView`：
- `wantsLayer=true`，`layer.contents` 直接接收 `CGImage`。
- `viewDidMoveToWindow`：每次 view 出现时重连 `mpvController.onNeedsDisplay`（窗口关闭再开时自动重新绑定）。
- `setFrameSize` 覆盖：SwiftUI 改尺寸走这里，不走 `layout()`，必须在此更新 `renderW/H`。

### 字幕流水线

`SubtitleExtractor` 两阶段：
1. **立即阶段**（`extractImmediate`）：并发提取流 0/1，伴随文件优先，快速呈现首屏字幕。
2. **后台阶段**（`listTracksWithLabels`）：解析 `ffmpeg -i` stderr 获取完整轨道信息，`preCacheOtherTracks` 后台预缓存所有轨道。

`SubtitleMode`（`single` / `bilingual`）实现 `Hashable`，作为 `[SubtitleMode: [Subtitle]]` 缓存键。

**默认轨道策略**（`autoSelectMode`）：始终加载 `tracks[0]`（第一个检测到的轨道），用户通过侧边栏 Chip 手动切换双语。

### 字幕状态双索引

| 变量 | 含义 | 用途 |
|------|------|------|
| `currentSubtitleIndex` | 当前时间命中的字幕（两条字幕之间为 -1） | 视频浮层文字、底部字幕栏、复制按钮 |
| `sidebarHighlightIndex` | 最近命中过的字幕，只前进不后退（永不退回 -1） | 侧边栏行高亮、自动滚动 |

`syncCurrentSubtitle(at:)` 同时维护两者；新视频/切轨时都重置为 -1。

### 字幕显示架构

**mpv 内置字幕渲染已禁用**（`sub-visibility=no`），由 SwiftUI 层统一管理：

- **视频浮层**（`videoSubtitleOverlay`）：ZStack 顶层，读 `subtitles[currentSubtitleIndex].cleanText`，受 `showSubtitles` 控制。
- **底部字幕栏**：`NavigationBarView.subtitleLabel`，同样受 `showSubtitles` 控制。

切换轨道或隐藏字幕后两处自动同步，无需向 mpv 发命令。

### Apple ID 设备绑定

- **打包**：`make_app.sh` 读取 Apple ID（`-a` 自动 / `-i` 指定 / 手动输入），写入 `Info.plist` 的 `BoundAppleID` 键。
- **运行时**：`LicenseCheck.validateOrQuit()` 在 `App.init()` 中调用，读取 `~/Library/Preferences/MobileMeAccounts.plist`，与 `Bundle.main.infoDictionary["BoundAppleID"]` 对比；不匹配则弹 NSAlert "请联系软件授权：wx DC_Wen" 后退出。
- `BoundAppleID` 为空时（开发模式）跳过检查。

### C ABI 说明

`MPVController` 所有 libmpv 函数指针通过 `sym<T>(_:)` + `unsafeBitCast` 从 `dlsym` 转换。  
`MPVRenderParam`：`type: Int32` + 4 字节 `_pad`，总 16 字节，与 C 端 `mpv_render_param` 对齐。  
字符串参数（如 `"sw"`）必须用 `withCString` 嵌套传递，防止 ARC 提前释放。

---

## 已修复的 Bug 及根本原因

### Bug 1 — 视频黑屏（只有声音，无画面）

| | |
|---|---|
| **现象** | 导入视频后音频正常播放，视频区域全黑 |
| **根本原因** | `mpv_render_context_create()` 在 `loadfile` **之后**调用。mpv 在 `loadfile` 时寻找 VO，若 context 尚未建立则跳过视频解码管线，后续无法补救 |
| **修复** | `setupRenderContext()` 移到 `cmd(["loadfile", ...])` 之前 |
| **文件** | `MPVController.swift` — `prepare(url:)` |

### Bug 2 — 播放/暂停、音量命令无效

| | |
|---|---|
| **现象** | 点击暂停或拖动音量滑块无效果 |
| **根本原因** | `cmd(["set_property", ...])` — `set_property` 是 Lua 脚本 API，不是 `mpv_command` 的合法命令；静默失败 |
| **修复** | 全部改为 `cmd(["set", "pause", "yes"])` / `cmd(["set", "volume", "50"])` |
| **文件** | `MPVController.swift` — `setPlaying()`, `setVolume()` |

### Bug 3 — 键盘快捷键 A/S/D 不生效

| | |
|---|---|
| **现象** | 按 A/S/D 无反应 |
| **根本原因 1** | SwiftUI `.keyboardShortcut` 作用于零尺寸隐形 Button 时在 macOS 上不可靠 |
| **根本原因 2** | `event.charactersIgnoringModifiers?.lowercased()` 依赖键盘布局，中文输入法下可能失败 |
| **修复** | `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` + `event.keyCode`（A=0, S=1, D=2, Space=49），`onAppear` 注册 |
| **文件** | `ContentView.swift` — `ContentView.body.onAppear` |

### Bug 4 — 字幕导航后暂停按钮未同步为播放状态

| | |
|---|---|
| **现象** | 暂停时点字幕导航，视频恢复播放，但按钮图标仍为「播放」 |
| **根本原因** | `jumpToSubtitle()` 调用 `mpv.setPlaying(true)` 但未更新 `PlayerViewModel.isPlaying` |
| **修复** | 两个分支（MPV / AVPlayer）均加 `isPlaying = true` |
| **文件** | `PlayerViewModel.swift` — `jumpToSubtitle()` |

### Bug 5 — 隐藏字幕时视频浮层仍显示

| | |
|---|---|
| **现象** | 点「隐藏字幕」后底部栏消失，但视频画面字幕依然可见 |
| **根本原因** | mpv 默认自行渲染字幕并烘焙进视频帧，SwiftUI 的 `showSubtitles` 不影响 mpv 渲染管线 |
| **修复** | `opt("no", "sub-visibility")` 禁用 mpv 字幕；改用 SwiftUI `videoSubtitleOverlay`，统一由 `showSubtitles` 驱动 |
| **文件** | `MPVController.swift` — `prepare()`；`ContentView.swift` — `videoSubtitleOverlay` |

### Bug 6 — 双语字幕显示三行（英文+中文+英文）

| | |
|---|---|
| **现象** | 双语模式字幕出现「ENG\nCHN\nENG」 |
| **根本原因** | 主轨道字幕已包含 "ENG\nCHN"，合并时朴素追加次轨道行，导致英文重复 |
| **修复** | `mergeBilingual()` 改为行级去重：将主轨道行放入 Set，次轨道中命中的行跳过 |
| **文件** | `SubtitleExtractor.swift` — `mergeBilingual()` |

### Bug 7 — 轨道标签显示「Track 1」而非语言名

| | |
|---|---|
| **现象** | ffmpeg 无语言标签时，选项 Chip 显示「Track 1」 |
| **根本原因** | 无 `language` 元数据时直接使用 `track.displayName` |
| **修复** | `trackLabel(for:)` 新增内容检测：抽取前 15 条字幕，比较 CJK/Latin 字符比例，推断语言 |
| **文件** | `PlayerViewModel.swift` — `trackLabel(for:)`；`SubtitleExtractor.swift` — `languageLabel(from:)` |

### Bug 8 — 字幕间隙时侧边栏高亮丢失

| | |
|---|---|
| **现象** | 两条字幕之间无字幕的时段，侧边栏高亮消失，用户不知道当前位置 |
| **根本原因** | `currentSubtitleIndex` 在间隙时置为 -1，侧边栏直接绑定此值 |
| **修复** | 新增 `sidebarHighlightIndex`：只在有字幕命中（`idx >= 0`）时更新，永不退回 -1；侧边栏改用此值 |
| **文件** | `PlayerViewModel.swift`；`SubtitleListView.swift` |

### Bug 9 — 关窗后再开回到初始状态（视频仍后台播放）

| | |
|---|---|
| **现象** | 点红 X 关窗，从 Dock 重新打开，显示空白"选择视频"界面，但 mpv 仍在后台播放 |
| **根本原因** | `PlayerViewModel` 用 `@StateObject` 创建在 `ContentView`，关窗时 view 被销毁，VM 随之销毁（新窗口创建全新 VM），但 mpv 生命周期与 VM 未完全同步 |
| **修复** | 将 VM 提升至 `App` 级别：`VideoSubtitleApp` 持有 `@StateObject var playerVM`，通过 `.environmentObject()` 注入；`ContentView` 改用 `@EnvironmentObject` |
| **文件** | `App.swift`；`ContentView.swift` |

---

## 规律总结

1. **mpv 初始化顺序严格**：render context 必须在 `loadfile` 之前创建，否则 VO 初始化失败且不可恢复。
2. **mpv 命令字符串**：`mpv_command` 用 `"set"` 设置属性；`"set_property"` 是 Lua API，二者不可混用。
3. **macOS 键盘拦截**：SwiftUI `.keyboardShortcut` 对无修饰键的单字母快捷键不可靠；`NSEvent.addLocalMonitorForEvents` + `keyCode` 是唯一可靠方案。
4. **UI 状态与后端同步**：凡通过 mpv 命令改变播放状态的地方，必须同时更新 `@Published` 变量，否则 SwiftUI 视图漂移。
5. **字幕渲染归属**：若需 SwiftUI 层控制字幕（显隐/切轨），必须禁用 mpv 内置渲染，否则无法统一管理两套系统。
6. **有状态 View Model 的生命周期**：持有重型资源（网络连接、媒体播放器）的 VM 应放在 App 级别，避免随窗口销毁。
7. **侧边栏索引与活跃索引分离**：UI 呈现（高亮/滚动）和逻辑状态（当前是否命中字幕）需要分开维护，避免"间隙归零"导致 UI 跳动。
