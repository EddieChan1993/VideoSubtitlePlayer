# VideoSubtitlePlayer

macOS 视频字幕播放器，专为语言学习设计。加载视频后自动提取字幕，支持双语显示、字幕跳转导航、听力练习模式（一键隐藏字幕）。

---

## 功能特性

| 功能 | 说明 |
|------|------|
| **全格式播放** | 通过 libmpv 播放 MKV / MP4 / MOV / AVI / WebM 等，无格式限制 |
| **字幕自动提取** | 提取内嵌字幕轨道（SRT / ASS / VTT），也支持同名伴随文件 |
| **双语模式** | 自动配对中英轨道并合并显示，重复行去重 |
| **视频字幕浮层** | 字幕直接叠加在视频画面上，切轨后自动同步 |
| **听力练习** | 一键隐藏/显示字幕（视频浮层 + 底部栏同步） |
| **三键导航** | 上一条 / 重播当前 / 下一条，支持键盘快捷键 A / S / D |
| **播放控制** | 播放/暂停（Space）、回到片头、音量滑块 |
| **复制字幕** | 一键复制当前字幕文本到剪贴板 |
| **侧边栏** | 字幕列表实时高亮，点击跳转；可折叠隐藏 |

---

## 系统要求

- **macOS 14 (Sonoma)** 或更高
- **libmpv**（视频播放）
- **FFmpeg**（字幕提取）

```bash
brew install mpv ffmpeg
```

---

## 快速开始

### 方式一：直接运行（开发模式）

```bash
git clone https://github.com/EddieChan1993/VideoSubtitlePlayer.git
cd VideoSubtitlePlayer
swift run
```

### 方式二：打包为 .app（推荐）

```bash
./make_app.sh
# 生成 VideoSubtitlePlayer.app，双击即可打开
open VideoSubtitlePlayer.app

# 可选：移动到 Applications
mv VideoSubtitlePlayer.app /Applications/
```

> **首次打开提示**：macOS Gatekeeper 可能弹出安全警告，右键 → 打开 即可。  
> 或执行：`xattr -rd com.apple.quarantine VideoSubtitlePlayer.app`

---

## 使用方式

1. 拖入视频文件，或点击「选择视频…」/ ⌘O
2. 字幕自动提取并显示在右侧列表及视频画面上
3. 顶部轨道 Chip 切换单语（英文）/ 双语（中/英）
4. 底部控制栏从左到右：

```
■  ▶  |  ⏮  ↺  ⏭  |  👁  |  当前字幕文本  [复制]  …  音量  位置  侧边栏
```

### 键盘快捷键

| 键 | 功能 |
|----|------|
| `A` | 上一条字幕 |
| `S` | 重播当前字幕起点 |
| `D` | 下一条字幕 |
| `Space` | 播放 / 暂停 |
| `⌘O` | 打开视频文件 |

---

## 技术说明

### 视频渲染

- 使用 **libmpv Render API**（`mpv_render_context_create`，SW 模式）
- 渲染输出为 `CGImage`，设置到 `CALayer.contents` 显示
- 回调驱动：`onNeedsDisplay` → 后台队列渲染 → 主线程更新 Layer
- 关键顺序：**render context 必须在 `loadfile` 之前创建**，否则 mpv 跳过 VO 初始化导致黑屏

### 内存与性能优化

- 像素缓冲区**持久复用**：仅在分辨率变化时重新分配（消除每帧 ~3 MB 的 malloc/free 抖动）
- `CFDataCreate` 为 CGImage 做单次 memcpy，比重复大块分配释放开销更低且无堆碎片
- `pendingRender` 标志防止渲染队列堆积，自然限速在单帧处理时间

### 字幕管线

- **两阶段提取**：立即提取流 0/1 快速显示，后台再解析完整轨道信息
- **双语去重**：合并时按行对比，过滤掉次要轨道中与主轨道重复的行
- **语言检测**：优先读取 ffmpeg 语言标签；无标签时从字幕内容检测（CJK/Latin 字符比例）
- **模式缓存**：`[SubtitleMode: [Subtitle]]` 字典缓存，切换轨道无需重新提取

### mpv 命令规范

通过 `mpv_command` 发送的属性设置命令使用 `"set"`，**不是** `"set_property"`（后者是 Lua 脚本 API）：

```swift
cmd(["set", "pause", "yes"])    // ✓
cmd(["set_property", ...])      // ✗ 无效，静默失败
```
