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

### Bug 17 — 字幕跳转后视频慢于音频并加速追赶
| | |
|---|---|
| **现象** | 点击字幕跳转后，视频定位到目标位置，但播放约 1 秒内画面明显落后于音频，随后加速赶上；在正常 MP4 视频上不复现 |
| **根本原因** | 视频源为外挂字幕格式，但英文轨道字幕与双语轨道字幕的时间戳存在偏差（非内嵌字幕）；将视频转为内嵌字幕格式（ffmpeg `-c:s copy` 封装）后，时间戳对齐，seek 精度恢复正常 |
| **修复** | 通过 ffmpeg 将外挂字幕内嵌到视频容器（生成新 MKV/MP4），使所有轨道时间基准一致，消除跳转后音画追赶现象 |
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
