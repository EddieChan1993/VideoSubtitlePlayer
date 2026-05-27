# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 构建与运行

```bash
swift build                                        # 编译
swift run                                          # 编译并运行
swift build 2>&1 | grep -E "error:|Build complete" # 只看错误/结果
```

无 Xcode 工程，无沙盒限制，以 `swift run` 方式运行。macOS 14+ 目标平台。

## 打包为 .app（SubMelon）

```bash
./make_app.sh                                  # 不绑定，生成 SubMelon.app
./make_app.sh -a                               # 自动读取当前登录 Apple ID
./make_app.sh -i user@icloud.com               # 单用户
./make_app.sh -i u1@x.com,u2@y.com,u3@z.com   # 批量，逗号分隔
./make_app.sh -l ids.txt                       # 批量，文件每行一个 Apple ID
./make_app.sh -h                               # 帮助
```

**打包产物命名规则：**
- 不绑定 → `SubMelon.app`
- 绑定 `hat666666@163.com` → `SubMelon-hat666666.app`（取 @ 前的用户名）

**打包流程（make_app.sh 内部）：**
1. 生成图标（`swift make_icon.swift` → `iconutil`）
2. `swift build -c release` 编译
3. 组装暂存目录（含 libmpv + ffmpeg 依赖，仅做一次）
4. 对每个 Apple ID：复制暂存 → 写 Info.plist → 签名
5. 清理暂存，输出所有 .app 列表

**接收方首次打开（绕过 Gatekeeper）：**
```bash
xattr -rd com.apple.quarantine SubMelon-xxx.app
```
或右键 → 打开 → 打开。

## 依赖

构建机需要 `brew install mpv ffmpeg`，make_app.sh 会自动将以下内容打包进 .app：

| 文件 | 位置 | 说明 |
|------|------|------|
| libmpv.dylib + 50 个依赖 dylib | `Contents/Frameworks/` | 视频解码，`dlopen` 加载 |
| ffmpeg 二进制 | `Contents/MacOS/ffmpeg` | 字幕提取子进程 |

所有 Homebrew 路径已被 `install_name_tool` 改写为 `@executable_path/../Frameworks/`。
**接收方无需安装任何依赖，即开即用。**

代码查找顺序（Bundle 优先，开发期 fallback 到 Homebrew）：
- `SubtitleExtractor.ffmpegPath`：先找 `Bundle/MacOS/ffmpeg`，再找 Homebrew
- `MPVController.libraryPath`：先找 `Bundle/Frameworks/libmpv.dylib`，再找 Homebrew

---

## 架构概览

### 应用生命周期

`PlayerViewModel` 创建在 `App` 级别（`VideoSubtitleApp` 的 `@StateObject`），通过 `.environmentObject()` 传给 `ContentView`。  
**不要**将 VM 放在 `ContentView` 的 `@StateObject`——关窗口会销毁 VM，再开窗口时视频状态丢失，且 mpv 仍在后台播放。

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
- `viewDidMoveToWindow`：每次 view 出现时重连 `mpvController.onNeedsDisplay`。
- `setFrameSize` 覆盖：SwiftUI 改尺寸走这里，不走 `layout()`，必须在此更新 `renderW/H`。
- `hasPendingFrame`：渲染进行中收到新帧时置 true，渲染完成后立即补渲一帧，防止帧丢失。

### 字幕流水线

`SubtitleExtractor` 两阶段：
1. **立即阶段**（`extractImmediate`）：并发提取流 0/1，伴随文件优先，快速呈现首屏字幕。
2. **后台阶段**（`listTracksWithLabels`）：解析 `ffmpeg -i` stderr 获取完整轨道信息，`preCacheOtherTracks` 后台预缓存所有轨道（延迟 2 秒启动，避免与 MPV 争 CPU）。

`SubtitleMode`（`single` / `bilingual`）实现 `Hashable`，作为 `[SubtitleMode: [Subtitle]]` 缓存键。

**默认轨道策略**（`autoSelectMode`）：始终加载 `tracks[0]`，用户通过侧边栏 Chip 手动切换双语。  
**双语 Tab 标签**：固定显示"双语"，不随语言检测结果变化。

### 字幕状态双索引

| 变量 | 含义 | 用途 |
|------|------|------|
| `currentSubtitleIndex` | 当前时间命中的字幕（间隙时为 -1） | 视频浮层文字、底部字幕栏、复制按钮 |
| `sidebarHighlightIndex` | 最近命中过的字幕，只前进不后退（永不退回 -1） | 侧边栏行高亮、自动滚动 |

`syncCurrentSubtitle(at:)` 同时维护两者；新视频/切轨时都重置为 -1。

### 字幕显示架构

**mpv 内置字幕渲染已禁用**（`sub-visibility=no`），由 SwiftUI 层统一管理：

- **视频浮层**（`videoSubtitleOverlay`）：ZStack 顶层，读 `subtitles[currentSubtitleIndex].cleanText`，受 `showSubtitles` 控制。
- **底部字幕栏**：`NavigationBarView.subtitleLabel`，锁定到 `sidebarHighlightIndex`（间隙时保持上一条）。

### Apple ID 授权绑定

- **打包**：`make_app.sh` 将 Apple ID 写入 `Info.plist` 的 `BoundAppleID` 键，文件名取用户名前缀（`@` 前）。
- **运行时**：`LicenseCheck.validateOrQuit()` 在 `App.init()` 中调用，读取 `~/Library/Preferences/MobileMeAccounts.plist`，与 `Bundle.main.infoDictionary["BoundAppleID"]` 对比；不匹配则弹 NSAlert "请联系软件授权：wx DC_Wen" 后退出。
- `BoundAppleID` 为空时（开发模式）跳过检查。
- **批量打包**：编译 + 依赖打包只做一次，每个 Apple ID 只复制暂存 + 写 plist + 签名，效率高。

### 字幕导出（CSV）

`PlayerViewModel.exportSubtitlesAsCSV()` 导出当前字幕轨道：
- 触发 `NSSavePanel`，默认文件名为 `<视频名>.csv`
- UTF-8 BOM 头（`\u{FEFF}`）确保 Excel 正确识别中文
- 列：序号 / 开始时间 / 结束时间 / 字幕
- 工具栏右侧「导出字幕」按钮触发；无字幕时禁用

### 强制侧边栏滚动机制

`sidebarScrollTrigger: Int`（`@Published`）每次切轨或异步加载完成时 `+= 1`。  
`SubtitleListView` 的 `onChange(of: vm.sidebarScrollTrigger)` 响应，调用 `proxy.scrollTo(sidebarHighlightIndex)`。  
解决 `sidebarHighlightIndex` 值不变时 `onChange` 不触发的问题。

### 历史记录与缩略图

- **`VideoHistory`**：`UserDefaults` 持久化，最多 50 条，`HistoryEntry` 含 `videoPath / videoTitle / lastOpened / externalSubtitlePaths`。
- **`ThumbnailCache`**：`NSCache`（60 条）+ 磁盘（`~/Library/Caches/SubMelon/thumbnails/`）双层缓存；文件名用 djb2 稳定哈希（`String.hashValue` 跨进程不稳定）。
- **`loadVideoThumbnail`**：命中缓存直接返回；未命中时在 `Task.detached(priority: .background)` 里调用 `generateThumbnail`，不阻塞主线程。
- **`generateThumbnail`**：AVFoundation 优先（`AVAssetImageGenerator`，容差 ±5 秒），失败时 ffmpeg 子进程兜底；截帧位置为 `duration / 2`。
- **MKV 时长问题**：`AVURLAsset.load(.duration)` 对 MKV 返回 0；通过 `ffmpegDuration()` 解析 `ffmpeg -i` stderr 的 `Duration: HH:MM:SS.ss` 获取真实时长，再定位中间帧。
- **ffmpeg 单帧输出**：新版 ffmpeg 要求加 `-update 1` 才能输出单张 JPEG，否则非零退出。
- 删除历史条目 / 清空历史时同步清理对应磁盘缩略图（`ThumbnailCache.remove` / `removeAll`）。

### 字幕轨道 Chip 拖拽排序

- `chipOrder: [String]`（`@Published`，VM 持有）存储 stableId 列表，切视频时重置为空。
- `stableId`：`"s{track.id}"` 或 `"b{primary.id}_{secondary.id}"`，不依赖可变的 label 字符串。
- `SubtitleListView` 的 `orderedOptions` 按 `chipOrder` 重排，新出现的轨道追加到末尾。
- 拖拽通过 `onDrag` + `ChipDropDelegate`（`DropDelegate`）实现；`dropEntered` 时实时移动数组，`performDrop` 时清除 draggedId。
- `orderedModes`（键盘快捷键 1/2/3 的顺序）依赖 `chipOrder` 构造，拖拽后快捷键自动跟随。
- Chip 区包裹在 `ScrollView(.horizontal)` 中，防止过多轨道挤压右侧控件。

### 侧边栏宽度拖拽（ResizeHandle）

- 纯 SwiftUI `DragGesture` 被下方 `NSScrollView` 截获，拖拽无效。
- 改用 `NSViewRepresentable` 包装 `_ResizeHandleNSView: NSView`，在 `mouseDown` / `mouseDragged` AppKit 事件中直接更新 `sidebarWidth`。
- 拖拽 view 宽度固定 8pt，加 `.clipped()` 防止子视图溢出遮挡拖拽区域。
- `SubtitleListView` 整体加 `.clipped()`，Chip 区用 `ScrollView(.horizontal)` 防止溢出。

### C ABI 说明

`MPVController` 所有 libmpv 函数指针通过 `sym<T>(_:)` + `unsafeBitCast` 从 `dlsym` 转换。  
`MPVRenderParam`：`type: Int32` + 4 字节 `_pad`，总 16 字节，与 C 端 `mpv_render_param` 对齐。  
字符串参数（如 `"sw"`）必须用 `withCString` 嵌套传递，防止 ARC 提前释放。

---

## 已修复的 Bug

### Bug 1 — 视频黑屏（只有声音，无画面）
| | |
|---|---|
| **现象** | 导入视频后音频正常播放，视频区域全黑 |
| **根本原因** | `mpv_render_context_create()` 在 `loadfile` **之后**调用，VO 初始化失败且不可补救 |
| **修复** | `setupRenderContext()` 移到 `cmd(["loadfile", ...])` 之前 |
| **文件** | `MPVController.swift` — `prepare(url:)` |

### Bug 2 — 播放/暂停、音量命令无效
| | |
|---|---|
| **现象** | 点击暂停或拖动音量滑块无效果 |
| **根本原因** | `cmd(["set_property", ...])` — `set_property` 是 Lua 脚本 API，`mpv_command` 不认；静默失败 |
| **修复** | 改为 `cmd(["set", "pause", "yes"])` / `cmd(["set", "volume", "50"])` |
| **文件** | `MPVController.swift` — `setPlaying()`, `setVolume()` |

### Bug 3 — 键盘快捷键 A/S/D 不生效
| | |
|---|---|
| **现象** | 按 A/S/D 无反应 |
| **根本原因 1** | SwiftUI `.keyboardShortcut` 对无修饰键的单字母在 macOS 上不可靠 |
| **根本原因 2** | `event.charactersIgnoringModifiers` 依赖键盘布局，中文输入法下可能失败 |
| **修复** | `NSEvent.addLocalMonitorForEvents` + `event.keyCode`（A=0, S=1, D=2, Space=49） |
| **文件** | `ContentView.swift` — `onAppear` |

### Bug 4 — 字幕导航后暂停按钮未同步
| | |
|---|---|
| **现象** | 暂停时点字幕导航，视频恢复播放，但按钮图标仍为「播放」 |
| **根本原因** | `jumpToSubtitle()` 调用 `mpv.setPlaying(true)` 但未更新 `isPlaying` |
| **修复** | 两个分支（MPV / AVPlayer）均加 `isPlaying = true` |
| **文件** | `PlayerViewModel.swift` — `jumpToSubtitle()` |

### Bug 5 — 隐藏字幕后视频浮层仍显示
| | |
|---|---|
| **现象** | 点「隐藏字幕」后底部栏消失，但视频画面字幕依然可见 |
| **根本原因** | mpv 默认自行渲染字幕并烘焙进帧，SwiftUI 的 `showSubtitles` 无法控制 |
| **修复** | `opt("no", "sub-visibility")` 禁用 mpv 字幕；改用 SwiftUI `videoSubtitleOverlay` |
| **文件** | `MPVController.swift` — `prepare()`；`ContentView.swift` — `videoSubtitleOverlay` |

### Bug 6 — 双语字幕显示三行（英文+中文+英文）
| | |
|---|---|
| **现象** | 双语模式出现「ENG\nCHN\nENG」 |
| **根本原因** | 主轨道已含「ENG\nCHN」，朴素追加次轨道导致英文重复 |
| **修复** | `mergeBilingual()` 行级去重 |
| **文件** | `SubtitleExtractor.swift` — `mergeBilingual()` |

### Bug 7 — 轨道标签显示「Track 1」
| | |
|---|---|
| **现象** | ffmpeg 无语言标签时，Chip 显示「Track 1」 |
| **修复** | `trackLabel(for:)` 内容检测：前 15 条字幕 CJK/Latin 字符比例推断语言 |
| **文件** | `PlayerViewModel.swift`；`SubtitleExtractor.swift` — `languageLabel(from:)` |

### Bug 8 — 字幕间隙时侧边栏高亮丢失
| | |
|---|---|
| **现象** | 两条字幕之间侧边栏高亮消失 |
| **根本原因** | `currentSubtitleIndex` 在间隙时置 -1，侧边栏直接绑定此值 |
| **修复** | 新增 `sidebarHighlightIndex`，只前进不退回 -1 |
| **文件** | `PlayerViewModel.swift`；`SubtitleListView.swift` |

### Bug 9 — 关窗后再开回到初始状态
| | |
|---|---|
| **现象** | 关窗再开，显示空白界面，mpv 仍在后台播放 |
| **根本原因** | VM 在 `ContentView` 的 `@StateObject`，关窗时销毁 |
| **修复** | VM 提升至 App 级别，`@EnvironmentObject` 注入 |
| **文件** | `App.swift`；`ContentView.swift` |

### Bug 10 — 音量滑块 50% 但实际音量 100%
| | |
|---|---|
| **现象** | 滑块在中间，声音却是最大 |
| **根本原因** | `switchToMPV` 未调用 `setVolume`；MPV 默认 100% |
| **修复** | `ctrl.prepare()` 后立即 `ctrl.setVolume(volume)` |
| **文件** | `PlayerViewModel.swift` — `switchToMPV()` |

### Bug 11 — 切换字幕轨道后侧边栏不定位
| | |
|---|---|
| **现象** | 点「双语」Tab，字幕列表停在顶部 |
| **根本原因** | `sidebarHighlightIndex` 值未变时 `onChange` 不触发 |
| **修复** | 新增 `sidebarScrollTrigger` 自增强制触发滚动 |
| **文件** | `PlayerViewModel.swift`；`SubtitleListView.swift` |

### Bug 12 — 来回切换视频时侧边栏字幕不刷新
| | |
|---|---|
| **现象** | 切换到新视频后，侧边栏仍显示旧视频的字幕，或旧字幕在短暂空白后重新出现 |
| **根本原因** | `loadVideo` 启动的字幕提取 `Task` 未保存引用，切换视频时无法取消；旧 Task 在 1.5 秒延迟后醒来，将旧视频字幕写入 `subtitles` / `availableTracks` |
| **修复** | 新增 `extractionTask: Task<Void, Never>?`，`loadVideo` 时先 `cancel()` 旧 Task；`extractSubtitles` 内两个关键 `await` 点后检查 `Task.isCancelled` 和 `videoURL == url`，双重保险 |
| **文件** | `PlayerViewModel.swift` — `loadVideo()`、`extractSubtitles(from:)` |

### Bug 13 — 切换视频后画面卡死在旧帧
| | |
|---|---|
| **现象** | 来回切换历史记录视频时，画面停在切换前的旧帧，无法播放新视频 |
| **根本原因** | `mpvController` 未声明 `@Published`，SwiftUI 在同一 RunLoop 内将 `useMPV false→true` 合并为无变化，`MPVPlayerView.updateNSView` 从不调用，旧 `MPVHostView` 持有旧 controller |
| **修复** | `mpvController` 改为 `@Published`；实现 `updateNSView`，检测 controller 变化时调用 `reconnect(to:)` 重连 `onNeedsDisplay` 回调 |
| **文件** | `PlayerViewModel.swift`；`MPVPlayerView.swift` — `MPVHostView.reconnect(to:)`、`MPVPlayerView.updateNSView` |

### Bug 14 — 字幕跳转后音画不同步（RealMedia / 低质量容器）
| | |
|---|---|
| **现象** | 点击字幕跳转后，音频落点错误，音画明显不同步；拖动进度条到字幕前手动播放则完全正常 |
| **根本原因** | `.rm` 文件使用 Cook 音频编解码器，RealMedia 容器的 seek 精度天然较低；`absolute+exact` seek 使视频定位到精确帧，但音频因 preroll/interleave 问题落到错误位置。mpv demuxer 选择**受文件扩展名影响**——扩展名 `.rm` 触发 RealMedia demuxer 的特殊 seek 路径，改成 `.mp4` 后 mpv 切换 demuxer，走标准 seek 路径，音频定位恢复正常 |
| **修复** | 检测到低质量 seek 格式（`.rm` `.rmvb` `.flv` `.avi` `.mpg` `.mpeg` `.vob` `.wmv` `.asf` `.ts`）时弹窗提示，提供"重命名为 .mp4"选项；`FileManager.moveItem` 直接改扩展名，无需重新编码，播放重命名后的文件 |
| **文件** | `PlayerViewModel.swift` — `offerConvertIfPoorSeek(url:)`；`loadVideo()` 调用处 |

### Bug 15 — 拖入字幕文件被当成视频处理
| | |
|---|---|
| **现象** | 将 `.srt` / `.ass` 等字幕文件拖入窗口后：① 字幕轨道语言识别失败（Chip 显示异常）；② 字幕文件被记录进视频历史 |
| **根本原因** | `handleDrop` 对所有拖入文件统一调用 `vm.loadVideo(url:)`，未区分视频与字幕文件；字幕文件应走 `loadExternalSubtitle`，手动选择走的是正确路径，拖入走的是错误路径 |
| **修复** | `handleDrop` 中判断扩展名，属于字幕格式（`srt/vtt/webvtt/ass/ssa`）则调 `vm.loadExternalSubtitle(from:autoSelect:true)`，否则调 `vm.loadVideo` |
| **文件** | `ContentView.swift` — `handleDrop(_:)` |

### Bug 16 — 双语模式显示重复英文行
| | |
|---|---|
| **现象** | 双语字幕列表中每条出现三行：英文 + 中文 + 英文（再来一遍） |
| **根本原因 1** | ffmpeg 将 ASS 格式的 `\N` 换行符原样写入 SRT 输出，`cleanText` 只按真换行符 `\n` 分割，导致「英文\N中文」被视为单行，与英文轨道的单行对不上，行级去重失效 |
| **根本原因 2** | `mergeBilingual()` 末尾会将所有未匹配到主轨的次轨（英文）条目无条件追加，当主轨已是双语格式时造成英文整轨重复 |
| **修复 1** | `cleanText` 补充 `\N` → `\n` 和 `\n`（字面量）→ `\n` 转换，确保分割和去重基于统一的换行格式 |
| **修复 2** | `mergeBilingual()` 开头检测主轨前 5 条：若 ≥ 2 条为多行且同时含 CJK 行和 Latin 行（≥4字符），视为主轨已是双语，直接返回主轨跳过合并 |
| **修复 3** | 移除 `mergeBilingual()` 末尾追加未匹配次轨条目的逻辑 |
| **文件** | `Subtitle.swift` — `cleanText`；`SubtitleExtractor.swift` — `mergeBilingual()` |

### Bug 17 — 内嵌字幕转换（convertToMKV）实现中遇到的问题

#### 17-A — ffmpeg 子进程 stderr 读取死锁
| | |
|---|---|
| **现象** | 调用 `proc.waitUntilExit()` 后进程永不退出，程序挂死 |
| **根本原因** | ffmpeg 输出量超过 pipe buffer（约 64 KB）时写端阻塞，但主线程在等 `waitUntilExit`，读端没人消费，双方互等死锁 |
| **修复** | 用 `DispatchGroup` + `DispatchQueue.global().async` 在后台线程消费 `readDataToEndOfFile()`，再 `waitUntilExit()`，保证 pipe 不满 |
| **文件** | `PlayerViewModel.swift` — `convertToMKV()` 内 `run(_:)` 函数 |

#### 17-B — 文件路径含 `[` `]` 特殊字符时 ffmpeg 报错
| | |
|---|---|
| **现象** | 视频文件名含 `[xxx]` 时，ffmpeg 报 `No such file or directory` |
| **根本原因** | ffmpeg 默认把 `[...]` 解析为 glob 模式，导致路径匹配失败 |
| **修复** | 所有传给 ffmpeg 的路径改用 `file:` 前缀（`"file:\(url.path)"`），强制按字面路径解析 |
| **文件** | `PlayerViewModel.swift` — `buildArgs(videoCodec:audioCodec:)` |

#### 17-C — 零时长字幕条目导致合并后字幕错位
| | |
|---|---|
| **现象** | 转换后的 MKV 字幕出现多条合并在一起或时间轴偏移 |
| **根本原因** | 原始 SRT 中存在 `start == end` 的零时长条目，ffmpeg 无法处理，会与相邻条目合并，打乱后续所有序号 |
| **修复** | `normalizeSRT()` 中跳过 `start == end` 的块，不写入标准化后的临时文件 |
| **文件** | `PlayerViewModel.swift` — `normalizeSRT(_:)` |

#### 17-D — GBK 编码字幕 / UTF-8 BOM 导致 ffmpeg 乱码
| | |
|---|---|
| **现象** | 内嵌后字幕显示乱码，或 ffmpeg 报编码错误 |
| **根本原因** | 国内常见字幕文件为 GBK 编码或带 UTF-8 BOM；ffmpeg 期望纯 UTF-8 无 BOM |
| **修复** | `prepareSubtitle(_:)` 依次尝试 UTF-8 → GB18030 解码，剥除 BOM，再统一输出为 UTF-8 临时文件交给 ffmpeg |
| **文件** | `PlayerViewModel.swift` — `prepareSubtitle(_:)` |

#### 17-E — SRT 时间戳格式不规范导致 ffmpeg 解析失败
| | |
|---|---|
| **现象** | 部分字幕文件封装后字幕为空 |
| **根本原因** | 一些 SRT 文件时间戳缺少前导零（如 `1:2:3,4` 而非 `01:02:03,004`），或 `-->` 前后无空格，ffmpeg 严格解析时跳过这些条目 |
| **修复** | `padSRTTime(_:)` 补齐两位小时/分/秒；`normalizeSRT()` 规范化 `-->` 前后空格 |
| **文件** | `PlayerViewModel.swift` — `padSRTTime(_:)`、`normalizeSRT(_:)` |

#### 17-F — 英中混排在同一行时双语去重失效
| | |
|---|---|
| **现象** | 内嵌后切换双语模式仍有英文重复 |
| **根本原因** | 部分字幕文件将英文和中文写在同一行（`English text. 中文文字。`），`mergeBilingual` 行级去重以 `\n` 分割，拿到的是整行，无法与英文轨的单行匹配 |
| **修复** | `splitMixedLine(_:)` 找到第一个 CJK 字符位置，将「英文前缀」和「中文后缀」拆成两行，再写入临时 SRT |
| **文件** | `PlayerViewModel.swift` — `splitMixedLine(_:)` |

#### 17-F2 — 零时长 SRT 条目内嵌后丢失
| | |
|---|---|
| **现象** | 原始外挂字幕中某些条目在转换为 MKV 内嵌字幕后消失，侧边栏比原来少若干条 |
| **根本原因** | 原始 SRT 文件中存在 `start == end` 的零时长条目（部分工具生成）；`normalizeSRT()` 为避免 ffmpeg 合并相邻条目，对这类条目执行 `continue` 直接跳过，导致内容丢失 |
| **修复** | 遇到 `start == end` 时，将 `end` 时间戳解析为毫秒后 +2000ms 再重新格式化为 `HH:MM:SS,mmm`，赋予 2 秒合成时长后保留条目，不再丢弃 |
| **文件** | `PlayerViewModel.swift` — `normalizeSRT(_:)` |

#### 17-G — 特定视频编码（rv30 等）不兼容 MKV 容器
| | |
|---|---|
| **现象** | 封装失败，ffmpeg 报 `Not yet implemented in FFmpeg` |
| **根本原因** | RealMedia `rv30`/`rv40` 等编码器无法直接复制进 MKV，必须重新编码 |
| **修复** | 两步策略：先以 `-c:v copy -c:a copy` 尝试直接封装；失败后弹窗询问用户，确认后改用 `-c:v libx264 -c:a aac` 重新编码 |
| **文件** | `PlayerViewModel.swift` — `convertToMKV()` 主流程 |

#### 17-H — 转换进度无法感知
| | |
|---|---|
| **现象** | 转换期间 UI 无进度反馈，用户不知道是否在处理 |
| **根本原因** | ffmpeg 默认进度输出夹杂大量日志，难以解析 |
| **修复** | 使用 `-progress pipe:2 -loglevel quiet`，ffmpeg 将结构化进度（`out_time=HH:MM:SS.ffffff`）单独写入 stderr，解析 `out_time` / 总时长得到百分比，通过 `convertingStatus` 更新 UI overlay |
| **文件** | `VideoConverter.swift` — `parseProgressTime(_:)`；`PlayerViewModel.swift` — `convertingStatus` |

### Bug 19 — 持续按住 A/D 键，字幕跳转越来越迟钝
| | |
|---|---|
| **现象** | 长按 A 或 D 键快速连跳字幕，跳转响应随时间推移越来越慢，最终几乎卡死 |
| **根本原因** | `seekExact`（`absolute+exact`）精度高但耗时，每次 seek 需等待 demuxer 精确定位到关键帧后解码；长按产生的 `NSEvent` key-repeat 事件以固定频率（~30Hz）涌入，seek 请求不断积压在 mpv 队列中，越堆越多，响应延迟指数级增长 |
| **尝试方向（已回退）** | 用 `NSEvent.isARepeat` 区分首次按键与 key-repeat；repeat 时改用 `absolute`（关键帧 seek，速度快但精度低）、单次按键保持 `seekExact`。实测体验更差：关键帧跳跃距离不可预期，字幕定位偏离，用户反馈"卡得很"，已回退 |
| **结论** | mpv seek 队列积压是根本瓶颈，单纯切换 seek 模式无法解决。正确方向应是：在发起新 seek 前取消/丢弃队列中尚未执行的旧 seek（如 `mpv_abort_async_command` 或在事件循环层做防抖节流），但改动复杂，暂未实现，维持现状（全部用 `seekExact`） |
| **文件** | `PlayerViewModel.swift` — `jumpToSubtitle()`、`nextSubtitle()`、`previousSubtitle()` |

### Bug 18 — 字幕跳转后视频慢于音频并加速追赶
| | |
|---|---|
| **现象** | 点击字幕跳转后，视频定位到目标位置，但播放约 1 秒内画面明显落后于音频，随后加速赶上；在正常 MP4 视频上不复现 |
| **根本原因** | 视频源为外挂字幕格式，但英文轨道字幕与双语轨道字幕的时间戳存在偏差（非内嵌字幕）；将视频转为内嵌字幕格式（ffmpeg `-c:s copy` 封装）后，时间戳对齐，seek 精度恢复正常 |
| **修复** | 通过 ffmpeg 将外挂字幕内嵌到视频容器（生成新 MKV/MP4），使所有轨道共享同一时间基准，消除跳转后音画追赶现象 |
| **文件** | `VideoConverter.swift` — 封装转换流程 |

---

## 规律总结

1. **mpv 初始化顺序严格**：render context 必须在 `loadfile` 之前创建，否则 VO 初始化失败且不可恢复。
2. **mpv 命令字符串**：`mpv_command` 用 `"set"` 设置属性；`"set_property"` 是 Lua API，二者不可混用。
3. **macOS 键盘拦截**：SwiftUI `.keyboardShortcut` 对无修饰键的单字母快捷键不可靠；`NSEvent.addLocalMonitorForEvents` + `keyCode` 是唯一可靠方案。
4. **UI 状态与后端同步**：凡通过 mpv 命令改变播放状态的地方，必须同时更新 `@Published` 变量，否则 SwiftUI 视图漂移。
5. **字幕渲染归属**：若需 SwiftUI 层控制字幕（显隐/切轨），必须禁用 mpv 内置渲染，否则无法统一管理。
6. **有状态 ViewModel 的生命周期**：持有重型资源的 VM 应放在 App 级别，避免随窗口销毁。
7. **侧边栏索引与活跃索引分离**：UI 呈现（高亮/滚动）和逻辑状态（是否命中字幕）需分开维护，避免间隙归零导致 UI 跳动。
8. **强制触发 SwiftUI onChange**：`onChange` 仅在值变化时触发；用专用自增 trigger 变量绕过"值相同不触发"的限制。
9. **MPV 初始状态同步**：MPV 实例创建后所有属性均为默认值，必须在 `prepare` 后立即同步 VM 的对应 `@Published` 值。
10. **动态库打包**：`install_name_tool -change` 修改引用路径后，对应 dylib 必须重新 `codesign`，否则签名校验失败。
11. **批量打包效率**：编译和 dylib 复制只做一次放进暂存目录，每个发行版只需 `cp -r staging` + 写 plist + 签名，避免重复耗时操作。
12. **后台 Task 必须保存引用**：`Task { }` 若不存入属性，切换状态时无法取消，旧任务会在 await 完成后用过期数据覆盖新状态；涉及视频切换的所有异步任务都要在 `loadVideo` 时 `cancel()`。
13. **AVFoundation 读不了 MKV 时长**：`AVURLAsset.load(.duration)` 对 MKV 返回 0；需用 ffmpeg 子进程解析 stderr 的 `Duration:` 行作为 fallback。
14. **新版 ffmpeg 单帧输出**：`ffmpeg -frames:v 1` 输出单张图片时必须加 `-update 1`，否则非零退出（即使文件已生成）。
15. **SwiftUI updateNSView 与 @Published**：`NSViewRepresentable.updateNSView` 仅在 SwiftUI 检测到 @Published 变化时调用；持有 AppKit 重型对象的属性若未加 `@Published`，视图切换时 `updateNSView` 不触发，宿主 view 持续引用旧对象。
16. **mpv demuxer 受文件扩展名影响**：同一个文件，扩展名 `.rm` 触发 RealMedia demuxer（seek 精度差），改名为 `.mp4` 后 mpv 切换 demuxer（seek 精度正常）。对低精度容器格式，直接 `FileManager.moveItem` 改后缀即可解决，无需 ffmpeg 重新编码。
17. **拖入与手动选择路径必须对齐**：`onDrop` 回调是独立入口，不会复用文件选择面板的逻辑。凡是手动选择支持的文件类型（如字幕），拖入处理函数也必须显式判断扩展名并路由到相同处理函数，否则两条路径行为不一致。
18. **ASS 换行符在 SRT 中的残留**：ffmpeg 将 ASS 字幕转换为 SRT 时，`\N`（硬换行）和 `\n`（软换行）可能以字面量字符串保留，而非转换为真正的换行符。任何对字幕文本做行级处理的逻辑（去重、显示、分割）都必须先将 `\N`/`\n` 转为真换行，否则多语言轨道合并会失效。
19. **外挂字幕 vs 内嵌字幕的 seek 精度**：外挂字幕文件（`.srt`/`.ass`）与视频本身使用独立的时间基准，英文轨和双语轨之间可能存在时间偏差，导致跳转后音画不同步（视频落后并加速追赶）。通过 ffmpeg 将字幕内嵌到容器，使所有轨道共享同一时间基准，可彻底消除此问题。
20. **ffmpeg 子进程 stderr 必须在后台异步消费**：`proc.waitUntilExit()` 前若未先消费 stderr pipe，输出量超过 pipe buffer（~64 KB）时写端阻塞，与 `waitUntilExit` 形成死锁。解决方案：用 `DispatchQueue.global().async` + `DispatchGroup` 在后台读完 stderr，再 wait。
21. **ffmpeg 路径中的特殊字符需 `file:` 前缀**：ffmpeg 对含 `[` `]` 的路径默认做 glob 解析，导致"No such file or directory"。在所有输入/输出路径前加 `file:` 前缀可强制字面量解析，与 URL encoding 无关。
22. **SRT 预处理是 ffmpeg 封装成功的前提**：字幕直接传给 ffmpeg 前需做四步标准化：① GBK/BOM → UTF-8；② `\r\n` / `\r` → `\n`；③ 时间戳补齐两位及规范 `-->` 空格；④ 零时长条目（`start == end`）赋予合成时长而非丢弃，否则内容丢失。任何一步缺失都可能导致封装后字幕为空、乱序或缺失。
23. **ffmpeg 进度解析用 `-progress pipe:2 -loglevel quiet`**：`-progress` 将结构化进度（`out_time=HH:MM:SS.ffffff` 等）写入指定 fd，与普通日志分离。结合总时长计算百分比，比解析 stderr 的 `frame=` 行更可靠。
24. **mpv seekExact 在高频按键下会积压队列**：`absolute+exact` seek 精度高但耗时；长按方向键产生的 key-repeat 事件速率（~30Hz）远超 seek 完成速率，请求堆积导致响应越来越慢。单纯切换为关键帧 seek（`absolute`）体验同样差（跳跃不可控）。正确做法是在发起新 seek 前丢弃未完成的旧 seek 请求（防抖/节流），而不是改变 seek 精度。
25. **whisper-cli 使用 ggml `.bin` 格式模型**：`whisper-cli`（whisper.cpp）使用 `.bin` 格式（ggml），而非 openai-whisper 的 `.pt` 格式，两者完全不兼容，导入文件选择器必须过滤 `.bin`。
26. **DispatchGroup.wait() 不能在 async 上下文调用**：Swift 6 会警告 `DispatchGroup.wait()` 在 async context 使用；解决方案是整个 Process 执行流放进 `withCheckedContinuation { continuation in DispatchQueue.global.async { ... group.wait() ... continuation.resume(...) } }`，把同步等待移到非 async 线程。
27. **fileImporter 会关闭 transient popover**：`.fileImporter`（底层是 `NSOpenPanel`）会让 macOS 关闭当前弹出窗口；解决方案是在 popover 内容 view 接受 `@Binding var isPresented: Bool`，在 fileImporter 结果回调里 `DispatchQueue.main.asyncAfter(0.1) { isPresented = true }` 重新打开。
28. **macOS 26 Translation.framework API 变化**：旧版 `TranslationSession(configuration:)` 不再适用；macOS 26 改为 `TranslationSession(installedSource: Locale.Language, target: Locale.Language?)`，需用 `#available(macOS 26, *)` 保护。

---

## 变更记录

### 2026-05-27
- 🆕 新增：双击视频画面切换播放/暂停
- 🐛 修复：字幕中 `[音乐]` 等括号注释跨行断开问题（`cleanText` 折叠括号内换行符）
- 🐛 修复：MKV 字幕内嵌超过 2 个 Tab 时弹窗拒绝，按钮始终可见不消失
- 🐛 修复：MKV 内嵌按用户 Tab 显示顺序统一处理所有来源（内嵌/伴随/外挂），不再把外挂固定追加到末尾
- 🐛 修复：Whisper 语音识别断句问题（`mergeAndSplitBySentence` 后处理，去掉 `-ml 42` 强制截断）
- ♻️ 优化：`PlayerViewModel` 加 `@unchecked Sendable`，消除 Swift 6 并发警告
- ♻️ 优化：NSCursor `push()/pop()` 全部改为 `.set()`，修复 tooltip 显示时光标从手指变回箭头的问题
- ♻️ 优化：TranscribeSettingsView UI 重构
  - Toggle 改为 checkbox 样式，去掉 iOS 风格蓝色粗条
  - 语言选择行去掉"源语言"文字和箭头，两个 Picker 居中排列
  - "当前模型"改为"Whisper 模型"白色标题，前置可点击 link icon 跳转官方模型下载页
  - 删除"替换模型"按钮，点击 chip 文字区域直接替换模型，chip 移除焦点蓝框
  - "开始识别"按钮改为全宽
  - 删除底部 ggml 格式提示文字

### 2026-05-26
- 🆕 新增：音量默认 30% 并通过 UserDefaults 持久化，重启后保留上次音量
- 🆕 新增：Whisper 语音转字幕功能（whisper-cli + ffmpeg pipeline，手动导入 `.bin` 模型，转录后自动加载字幕）
- 🆕 新增：双语字幕生成选项（macOS 26 Translation.framework，生成原语言 + 目标语言双字幕文件）
- 🆕 新增：build.sh 脚本（`--dev` 模式用 swift build debug；全量模式调用 make_app.sh；构建后自动启动 app）
- 🆕 新增：内置字幕轨道支持删除（removeBuiltInTrack）
- 🆕 新增：同名内置/外挂轨道自动加"（内置）"后缀区分，避免用户混淆
- ♻️ 优化：TranscribeSettingsView 弹窗在导入模型后自动保持开启状态
- ♻️ 优化：弹窗内所有按钮添加 hover / press 交互动效，移除被选中态
