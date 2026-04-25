# SubMelon

macOS 视频字幕播放器，专为语言学习设计。加载视频后自动提取字幕，支持双语显示、字幕导航、听力练习模式、字幕导出。

---

## 功能特性

| 功能 | 说明 |
|------|------|
| **全格式播放** | 通过 libmpv 播放 MKV / MP4 / MOV / AVI / WebM 等，无格式限制 |
| **字幕自动提取** | 内嵌字幕轨道（SRT / ASS / VTT）+ 同名伴随文件，两阶段异步提取 |
| **双语模式** | 自动配对中英轨道合并显示，重复行去重；轨道 2 固定标签「双语」 |
| **视频字幕浮层** | 字幕叠加在视频画面，切轨后自动同步 |
| **听力练习** | 一键隐藏/显示字幕（浮层与底部栏同步） |
| **三键导航** | 上一条 / 重播当前 / 下一条，键盘 A / S / D |
| **进度条** | 视频内嵌进度条，拖动时侧边栏实时定位对应字幕 |
| **字幕导出** | 导出当前轨道为 CSV，UTF-8 BOM，可直接用 Excel 打开 |
| **侧边栏** | 字幕列表实时高亮，点击跳转；间隙期间保持上一条高亮不丢位 |
| **播放控制** | 播放/暂停（Space）、回到片头、音量滑块 |
| **复制字幕** | 一键复制当前字幕到剪贴板 |
| **窗口状态保持** | 关窗再打开，视频和字幕状态完整恢复 |
| **即开即用** | 打包后内含 libmpv + ffmpeg，接收方无需安装任何依赖 |
| **授权绑定** | 打包时绑定 Apple ID，其他设备运行时弹窗拦截 |

---

## 系统要求

- **macOS 14 (Sonoma)** 或更高
- **构建机**需要（打包时自动内置，接收方不需要）：
  ```bash
  brew install mpv ffmpeg
  ```

---

## 快速开始

### 开发模式运行

```bash
git clone https://github.com/EddieChan1993/VideoSubtitlePlayer.git
cd VideoSubtitlePlayer
swift run
```

### 打包为 SubMelon.app

```bash
# 不绑定（任意设备可用）
./make_app.sh

# 绑定单个用户
./make_app.sh -i user@icloud.com

# 批量打包（逗号分隔）
./make_app.sh -i user1@icloud.com,user2@163.com,user3@qq.com

# 批量打包（从文件读取，每行一个 Apple ID）
./make_app.sh -l ids.txt

# 自动读取当前登录 Apple ID
./make_app.sh -a
```

**产物命名：**
- 不绑定 → `SubMelon.app`
- 绑定 `hat666666@163.com` → `SubMelon-hat666666.app`

**接收方首次打开（绕过 Gatekeeper）：**
```bash
xattr -rd com.apple.quarantine SubMelon-xxx.app
# 或右键 → 打开 → 打开
```

---

## 使用方式

1. 拖入视频，或点击「选择视频…」/ `⌘O`
2. 字幕自动提取，显示在右侧列表及视频画面
3. 侧边栏顶部 Chip 切换轨道：第一轨（英文）/ 双语
4. 工具栏右上角「导出字幕」→ 保存当前轨道为 CSV

**底部控制栏布局：**
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

## 授权绑定

打包时绑定 Apple ID，生成的 `.app` 只能在该账号登录的 Mac 上运行。其他设备打开时弹窗：

> **未授权设备** — 请联系软件授权：wx DC_Wen

批量打包时编译和依赖内置只做一次，每个用户仅额外耗费复制+签名时间，效率高。

---

## 技术说明

### 视频渲染

- **libmpv Render API**（SW 模式）：`mpv_render_context_create` → 后台队列渲染为 `CGImage` → 主线程写入 `CALayer.contents`
- `hasPendingFrame` 补渲机制：渲染进行中若收到新帧通知，完成后立即补渲一帧，避免丢帧
- **关键顺序**：render context 必须在 `loadfile` 之前创建，否则 VO 初始化失败且不可恢复
- 像素缓冲区持久复用，仅在分辨率变化时重新分配

### 字幕管线

- **两阶段提取**：立即提取流 0/1 快速显示首屏，后台完整解析所有轨道（延迟 2 秒启动，避让 MPV 初始化）
- **语言检测**：优先读 ffmpeg 语言标签；无标签时从内容检测（CJK/Latin 字符比例）
- **模式缓存**：`[SubtitleMode: [Subtitle]]` 字典，切换轨道无需重新提取
- **双语去重**：次要轨道中与主轨道重复的行按行过滤

### 即开即用打包原理

`make_app.sh` 使用递归 `bundle_dylib()` 函数：
1. `otool -L` 读取 Homebrew 依赖链
2. `cp` 复制到 `Contents/Frameworks/`
3. `install_name_tool -change` 将路径改写为 `@executable_path/../Frameworks/`
4. 递归处理所有间接依赖（共约 50 个 dylib）
5. `codesign` 对每个 dylib 单独签名后再整体签名

代码查找优先级：Bundle 内 → Homebrew → 系统路径，开发期 `swift run` 自动 fallback 到 Homebrew。
