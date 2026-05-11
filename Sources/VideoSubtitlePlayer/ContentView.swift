import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    // Provided by VideoSubtitleApp via .environmentObject(playerVM).
    // Lives at app level so the video/subtitle state survives window close/reopen.
    @EnvironmentObject private var vm: PlayerViewModel
    @State private var dropTargeted = false
    @State private var keyMonitor: Any?
    @State private var isSeeking = false
    @State private var seekValue: Double = 0
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 280
    @AppStorage("sub.fontSize")    private var subFontSize: Double = 18
    @AppStorage("sub.secFontSize") private var subSecFontSize: Double = 15
    @AppStorage("sub.bgOpacity")   private var subBgOpacity: Double = 0.55
    @AppStorage("sub.bottomPad")   private var subBottomPad: Double = 18
    @AppStorage("sub.cr")  private var subCR:  Double = 1
    @AppStorage("sub.cg")  private var subCG:  Double = 1
    @AppStorage("sub.cb")  private var subCB:  Double = 1
    @AppStorage("sub.scr") private var subSCR: Double = 1
    @AppStorage("sub.scg") private var subSCG: Double = 0.93
    @AppStorage("sub.scb") private var subSCB: Double = 0    // default secondary: yellow
    private var subColor:    Color { Color(red: subCR,  green: subCG,  blue: subCB)  }
    private var subSecColor: Color { Color(red: subSCR, green: subSCG, blue: subSCB) }
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            if vm.isVideoLoaded {
                playerLayout
            } else {
                homeLayout
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .onReceive(NotificationCenter.default.publisher(for: .openVideoFile)) { _ in
            vm.openFile()
        }
        .toolbar {
            if vm.isVideoLoaded {
                ToolbarItem(placement: .navigation) {
                    Button(action: vm.openFile) {
                        Label("打开视频", systemImage: "folder")
                    }
                    .help("打开视频文件 (⌘O)")
                }
                ToolbarItem(placement: .navigation) {
                    Button(action: vm.goHome) {
                        Label("回到首页", systemImage: "house")
                    }
                    .help("停止播放，回到首页")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: vm.exportSubtitlesAsCSV) {
                        Label("导出字幕", systemImage: "square.and.arrow.up")
                    }
                    .help("导出当前字幕为 CSV（可用 Excel 打开）")
                    .disabled(vm.subtitles.isEmpty)
                }
            }
        }
        .onAppear {
            // 先移除旧 monitor，防止多次 onAppear 时残留
            if let old = keyMonitor { NSEvent.removeMonitor(old); keyMonitor = nil }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
                // 本 app 内有文本输入框获焦时，放行事件让其正常输入
                let fr = NSApp.keyWindow?.firstResponder
                if fr is NSTextView || fr is NSTextField { return event }
                switch event.keyCode {
                case 13: vm.jumpToFirstSubtitle();    return nil  // W
                case 14: vm.jumpToLastSubtitle();     return nil  // E
                case 0:  vm.previousSubtitle();       return nil  // A
                case 1:  vm.restartCurrentSubtitle(); return nil  // S
                case 2:  vm.nextSubtitle();           return nil  // D
                case 8:  vm.copyCurrentSubtitle();    return nil  // C
                case 12: vm.showSubtitles.toggle();   return nil  // Q
                case 6:  withAnimation(.easeInOut(duration: 0.2)) { vm.showSidebar.toggle() }; return nil  // Z
                case 18: vm.selectTrackOption(at: 0); return nil  // 1
                case 19: vm.selectTrackOption(at: 1); return nil  // 2
                case 20: vm.selectTrackOption(at: 2); return nil  // 3
                case 21: vm.selectTrackOption(at: 3); return nil  // 4
                case 23: vm.selectTrackOption(at: 4); return nil  // 5
                case 49: vm.togglePlayPause();        return nil  // Space
                default: return event
                }
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
    }

    private var homeLayout: some View {
        HStack(spacing: 0) {
            DropZoneView(isTargeted: dropTargeted, onOpen: vm.openFile)
            if !VideoHistory.shared.entries.isEmpty {
                Divider()
                HistoryPanelView { entry in
                    vm.loadVideoFromHistory(entry)
                }
            }
        }
    }

    private var playerLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZStack {
                    if vm.useMPV, let mpv = vm.mpvController {
                        MPVPlayerView(controller: mpv)
                    } else {
                        VideoPlayerView(player: vm.player)
                    }
                    if vm.isPreparing {
                        preparingOverlay
                    } else if let err = vm.videoError {
                        videoErrorOverlay(err)
                    }
                    seekBarOverlay
                }
                .frame(minWidth: 420, minHeight: 280)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if vm.showSidebar {
                    SidebarResizeHandle(sidebarWidth: $sidebarWidth, minWidth: 240, maxWidth: 480)
                        .frame(width: 8)
                    SubtitleListView(vm: vm)
                        .frame(width: CGFloat(sidebarWidth))
                        .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            NavigationBarView(vm: vm)
        }
    }

    private var seekBarOverlay: some View {
        VStack(spacing: 0) {
            Spacer()
            // 字幕浮层先占位，进度条跟在下方，两者不重叠
            videoSubtitleOverlay
                .allowsHitTesting(false)
            HStack(spacing: 8) {
                Text(formatTime(isSeeking ? seekValue : vm.currentTime))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white)
                    .fixedSize()

                Slider(
                    value: Binding(
                        get: { isSeeking ? seekValue : vm.currentTime },
                        set: { v in
                            isSeeking = true
                            vm.isScrubbing = true
                            seekValue = v
                            vm.previewSubtitleIndex(for: v)
                        }
                    ),
                    in: 0...max(vm.videoDuration, 1)
                ) { editing in
                    if !editing {
                        vm.seek(to: seekValue)
                        isSeeking = false
                        vm.isScrubbing = false
                    }
                }
                .controlSize(.small)

                Text(formatTime(vm.videoDuration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.6)],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    @ViewBuilder
    private var videoSubtitleOverlay: some View {
        if vm.showSubtitles,
           vm.currentSubtitleIndex >= 0,
           vm.currentSubtitleIndex < vm.subtitles.count {
            let lines = vm.subtitles[vm.currentSubtitleIndex].bilingualLines
            if !lines.isEmpty {
                VStack {
                    Spacer()
                    VStack(spacing: 3) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: idx == 0 ? subFontSize : subSecFontSize,
                                              weight: .semibold))
                                .foregroundStyle(idx == 0 ? subColor : subSecColor)
                                .multilineTextAlignment(.center)
                                .shadow(color: .black, radius: 1, x: 1, y: 1)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(subBgOpacity))
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, subBottomPad)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
    }

    private var preparingOverlay: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Text("正在准备播放…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    private func videoErrorOverlay(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("无法播放")
                .font(.headline)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("复制安装命令") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install mpv", forType: .string)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            let url: URL? = {
                if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
                if let u = item as? URL { return u }
                return nil
            }()
            if let url { DispatchQueue.main.async { vm.loadVideo(url: url) } }
        }
        return true
    }
}

// MARK: - Drop Zone

struct DropZoneView: View {
    let isTargeted: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: isTargeted ? "film.stack.fill" : "film.stack")
                .font(.system(size: 52))
                .foregroundStyle(isTargeted ? Color.accentColor : Color(.tertiaryLabelColor))
                .animation(.spring(duration: 0.2), value: isTargeted)
            Text("拖入视频文件")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("或")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Button("选择视频…", action: onOpen)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("支持 MKV · MP4 · MOV · AVI 及伴随字幕文件")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 2, dash: isTargeted ? [] : [10, 6])
                )
                .animation(.spring(duration: 0.2), value: isTargeted)
                .padding(20)
        )
    }
}

// MARK: - Navigation Bar

struct NavigationBarView: View {
    @ObservedObject var vm: PlayerViewModel
    @State private var showSubSettings = false

    /// 底部栏锁定字幕：优先用侧边栏高亮（间隙时不清空），回退到当前播放
    private var locked: Subtitle? {
        let idx = vm.sidebarHighlightIndex >= 0 ? vm.sidebarHighlightIndex : vm.currentSubtitleIndex
        guard idx >= 0, idx < vm.subtitles.count else { return nil }
        return vm.subtitles[idx]
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {

                // ── 播放控制 ──────────────────────────────────
                BarButton(icon: "stop.fill", help: "回到片头", action: vm.stopPlayback)
                BarButton(icon: vm.isPlaying ? "pause.fill" : "play.fill",
                          help: vm.isPlaying ? "暂停 (Space)" : "播放 (Space)",
                          action: vm.togglePlayPause)

                barDivider

                // ── 字幕导航 ──────────────────────────────────
                BarButton(icon: "backward.end.alt.fill", help: "跳到第一条字幕 (W)",
                          disabled: vm.subtitles.isEmpty,
                          action: vm.jumpToFirstSubtitle)
                BarButton(icon: "backward.end.fill", help: "上一条字幕 (A)",
                          disabled: vm.sidebarHighlightIndex <= 0 && vm.subtitles.isEmpty,
                          action: vm.previousSubtitle)
                BarButton(icon: "arrow.counterclockwise", help: "回到锁定字幕起点 (S)",
                          disabled: vm.sidebarHighlightIndex < 0,
                          action: vm.restartLockedSubtitle)
                BarButton(icon: "forward.end.fill", help: "下一条字幕 (D)",
                          disabled: vm.sidebarHighlightIndex >= vm.subtitles.count - 1 || vm.subtitles.isEmpty,
                          action: vm.nextSubtitle)
                BarButton(icon: "forward.end.alt.fill", help: "跳到最后一条字幕 (E)",
                          disabled: vm.subtitles.isEmpty,
                          action: vm.jumpToLastSubtitle)

                barDivider

                // ── 字幕开关 + 样式 ───────────────────────────
                BarButton(icon: vm.showSubtitles ? "captions.bubble.fill" : "captions.bubble",
                          help: vm.showSubtitles ? "隐藏字幕（练听力）(Q)" : "显示字幕 (Q)",
                          tint: vm.showSubtitles ? nil : .secondary,
                          action: { vm.showSubtitles.toggle() })
                BarButton(icon: "textformat.size", help: "字幕样式设置") {
                    showSubSettings.toggle()
                }
                .popover(isPresented: $showSubSettings, arrowEdge: .top) {
                    SubtitleSettingsView()
                }

                barDivider

                // ── 字幕文本 + 复制（锁定字幕，间隙时保持上一条）───────
                subtitleLabel
                copyButton
                    .padding(.horizontal, 4)

                Spacer(minLength: 4)

                // ── 音量 ──────────────────────────────────────
                volumeControl
                    .padding(.trailing, 8)

                // ── 侧边栏 ───────────────────────────────────
                BarButton(icon: "sidebar.trailing",
                          help: vm.showSidebar ? "隐藏字幕列表 (Z)" : "显示字幕列表 (Z)",
                          tint: vm.showSidebar ? nil : .accentColor,
                          action: { withAnimation(.easeInOut(duration: 0.2)) { vm.showSidebar.toggle() } })
                    .padding(.trailing, 6)
            }
            .frame(height: 44)
            .background(.background)
        }
    }

    // MARK: helpers

    private var barDivider: some View {
        Divider().frame(height: 18).padding(.horizontal, 6)
    }

    private var subtitleLabel: some View {
        Group {
            if !vm.showSubtitles {
                Label("字幕已隐藏", systemImage: "eye.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else if let sub = locked {
                Text(sub.cleanText)
                    .font(.system(size: 12.5))
                    .lineLimit(2)
                    .foregroundStyle(vm.currentSubtitleIndex >= 0 ? .primary : .secondary)
            } else {
                Text(vm.isLoadingSubtitles ? "正在提取字幕…" : "—")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var copyButton: some View {
        BarButton(
            icon: vm.subtitleCopied ? "checkmark" : "doc.on.doc",
            help: "复制锁定字幕 (C)",
            tint: vm.subtitleCopied ? .accentColor : nil,
            disabled: locked == nil || !vm.showSubtitles,
            action: vm.copyCurrentSubtitle
        )
    }

    private var volumeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: vm.volume < 1 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Slider(value: $vm.volume, in: 0...100)
                .frame(width: 96)
                .controlSize(.mini)
        }
    }

}

// MARK: - BarButton  (unified icon button with hover + press feedback)

struct BarButton: View {
    let icon: String
    let help: String
    var tint: Color? = nil        // nil = inherit foreground
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .foregroundStyle(foregroundColor)
        }
        .buttonStyle(PressScaleStyle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered && !disabled
                      ? Color.primary.opacity(0.08)
                      : Color.clear)
                .animation(.easeOut(duration: 0.12), value: isHovered)
        )
        .disabled(disabled)
        .help(help)
        .onHover { isHovered = !disabled && $0 }
    }

    private var foregroundColor: Color {
        if disabled { return Color(.tertiaryLabelColor) }
        if let t = tint { return t }
        return Color.primary
    }
}

/// Scales down on press; no default button chrome.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.82 : 1.0)
            .animation(.easeOut(duration: 0.07), value: configuration.isPressed)
    }
}

// NavButton kept for any legacy call sites
typealias NavButton = BarButton

// MARK: - Subtitle appearance settings popover

struct SubtitleSettingsView: View {
    @AppStorage("sub.fontSize")    private var fontSize: Double = 18
    @AppStorage("sub.secFontSize") private var secFontSize: Double = 15
    @AppStorage("sub.bgOpacity")   private var bgOpacity: Double = 0.55
    @AppStorage("sub.bottomPad")   private var bottomPad: Double = 18
    @AppStorage("sub.cr")  private var cr:  Double = 1
    @AppStorage("sub.cg")  private var cg:  Double = 1
    @AppStorage("sub.cb")  private var cb:  Double = 1
    @AppStorage("sub.scr") private var scr: Double = 1
    @AppStorage("sub.scg") private var scg: Double = 0.93
    @AppStorage("sub.scb") private var scb: Double = 0

    // Classic bilingual color presets: (label, primary, secondary)
    private let presets: [(String, (Double,Double,Double), (Double,Double,Double))] = [
        ("白 / 黄", (1,1,1), (1,0.93,0)),
        ("白 / 白", (1,1,1), (1,1,1)),
        ("黄 / 白", (1,0.93,0), (1,1,1)),
    ]

    private var primaryColor: Binding<Color> { colorBinding(r: $cr, g: $cg, b: $cb) }
    private var secondaryColor: Binding<Color> { colorBinding(r: $scr, g: $scg, b: $scb) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("字幕样式").font(.headline)
                Spacer()
                Button("重置默认") { resetDefaults() }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            row("主字幕大小", value: $fontSize, range: 10...40, unit: "pt")
            row("双语副行大小", value: $secFontSize, range: 10...36, unit: "pt")
            row("背景透明度", value: $bgOpacity, range: 0...1, display: { "\(Int($0 * 100))%" })
            row("底部间距", value: $bottomPad, range: 0...80, unit: "pt")
            Divider()
            HStack {
                Text("主行颜色").font(.callout).frame(width: 72, alignment: .leading)
                ColorPicker("", selection: primaryColor, supportsOpacity: false).labelsHidden()
                Spacer()
                Text("副行颜色").font(.callout).frame(width: 72, alignment: .leading)
                ColorPicker("", selection: secondaryColor, supportsOpacity: false).labelsHidden()
            }
            HStack(spacing: 8) {
                Text("经典预设").font(.callout).foregroundStyle(.secondary)
                ForEach(presets, id: \.0) { preset in
                    Button {
                        (cr, cg, cb)   = preset.1
                        (scr, scg, scb) = preset.2
                    } label: {
                        HStack(spacing: 3) {
                            Circle().fill(Color(red: preset.1.0, green: preset.1.1, blue: preset.1.2))
                                .frame(width: 10, height: 10)
                                .overlay(Circle().strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5))
                            Circle().fill(Color(red: preset.2.0, green: preset.2.1, blue: preset.2.2))
                                .frame(width: 10, height: 10)
                                .overlay(Circle().strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5))
                            Text(preset.0).font(.system(size: 11))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color(.controlBackgroundColor)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func resetDefaults() {
        fontSize = 18; secFontSize = 15; bgOpacity = 0.55; bottomPad = 18
        cr = 1; cg = 1; cb = 1; scr = 1; scg = 0.93; scb = 0
    }

    private func colorBinding(r: Binding<Double>, g: Binding<Double>, b: Binding<Double>) -> Binding<Color> {
        Binding(
            get: { Color(red: r.wrappedValue, green: g.wrappedValue, blue: b.wrappedValue) },
            set: { c in
                guard let ns = NSColor(c).usingColorSpace(.deviceRGB) else { return }
                r.wrappedValue = Double(ns.redComponent)
                g.wrappedValue = Double(ns.greenComponent)
                b.wrappedValue = Double(ns.blueComponent)
            }
        )
    }

    private func row(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                     unit: String = "", display: ((Double) -> String)? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.callout).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
            Text(display?(value.wrappedValue) ?? "\(Int(value.wrappedValue))\(unit)")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 38, alignment: .trailing)
        }
    }
}

// MARK: - History popover

// MARK: - HistoryPanelView（首页侧边栏）

struct HistoryPanelView: View {
    @ObservedObject private var history = VideoHistory.shared
    var onSelect: (HistoryEntry) -> Void
    @State private var clearHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text("最近播放").font(.headline)
                Text("(\(history.entries.count))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            // List
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(history.entries) { entry in
                        HistoryRowView(entry: entry,
                                       onOpen: { onSelect(entry) },
                                       onDelete: { history.remove(entry) })
                        Divider().padding(.leading, 12)
                    }
                }
            }

            // Footer
            Divider()
            Button {
                history.clearAll()
            } label: {
                Text("清空全部")
                    .font(.system(size: 11))
                    .foregroundStyle(clearHovering ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(clearHovering ? Color(.controlColor) : Color.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { h in
                clearHovering = h
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .frame(width: 280)
        .background(.background)
    }
}

// MARK: - HistoryPopoverView（工具栏弹出，视频播放中不可见）

struct HistoryPopoverView: View {
    @ObservedObject var history: VideoHistory
    var onSelect: (HistoryEntry) -> Void
    @State private var clearHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text("最近播放").font(.headline)
                if !history.entries.isEmpty {
                    Text("(\(history.entries.count))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            // Content
            if history.entries.isEmpty {
                Text("暂无播放记录")
                    .foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity).padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(history.entries) { entry in
                            HistoryRowView(entry: entry,
                                           onOpen: { onSelect(entry) },
                                           onDelete: { history.remove(entry) })
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(history.entries.count), 8) * 62)

                // Footer
                Rectangle()
                    .fill(Color(.separatorColor))
                    .frame(height: 1)
                Button {
                    history.clearAll()
                } label: {
                    Text("清空全部")
                        .font(.system(size: 11))
                        .foregroundStyle(clearHovering ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(clearHovering ? Color(.controlColor) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { h in
                    clearHovering = h
                    if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
        .frame(width: 340)
    }
}

struct HistoryRowView: View {
    let entry: HistoryEntry
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var thumbnail: NSImage? = nil

    var body: some View {
        HStack(spacing: 10) {
            // 缩略图
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.windowBackgroundColor))
                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 45)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 80, height: 45)

            // 标题 + 外挂字幕数
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.videoTitle)
                    .font(.system(size: 12.5))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.externalSubtitlePaths.isEmpty {
                    Text("\(entry.externalSubtitlePaths.count) 个外挂字幕")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            DeleteButton(action: onDelete)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? Color(.controlColor) : Color.clear)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture { onOpen() }
        .task(id: entry.videoPath) {
            thumbnail = await loadVideoThumbnail(path: entry.videoPath)
        }
    }
}

// MARK: - Sidebar resize handle

// MARK: - DeleteButton

private struct DeleteButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(hovering ? Color(.secondaryLabelColor) : Color(.tertiaryLabelColor))
                .scaleEffect(hovering ? 1.15 : 1.0)
                .animation(.easeInOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { h in
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// NSViewRepresentable avoids SwiftUI DragGesture being stolen by the adjacent NSScrollView (List).
struct SidebarResizeHandle: NSViewRepresentable {
    @Binding var sidebarWidth: Double
    let minWidth: Double
    let maxWidth: Double

    func makeNSView(context: Context) -> _ResizeHandleNSView { _ResizeHandleNSView() }

    func updateNSView(_ nsView: _ResizeHandleNSView, context: Context) {
        nsView.binding = $sidebarWidth
        nsView.minWidth = minWidth
        nsView.maxWidth = maxWidth
    }
}

final class _ResizeHandleNSView: NSView {
    var binding: Binding<Double>?
    var minWidth: Double = 200
    var maxWidth: Double = 600

    private var dragStartX: CGFloat = 0
    private var dragStartWidth: Double = 0
    private var trackingArea: NSTrackingArea?
    private let lineLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        lineLayer.backgroundColor = NSColor.separatorColor.cgColor
        layer?.addSublayer(lineLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: NSView.noIntrinsicMetric) }

    override func layout() {
        super.layout()
        let x = (bounds.width - 1) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lineLayer.frame = CGRect(x: x, y: 0, width: 1, height: bounds.height)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseEntered(with event: NSEvent) {
        lineLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        lineLayer.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        dragStartWidth = binding?.wrappedValue ?? 280
    }
    override func mouseDragged(with event: NSEvent) {
        let delta = event.locationInWindow.x - dragStartX
        let newWidth = min(maxWidth, max(minWidth, dragStartWidth - delta))
        DispatchQueue.main.async { [weak self] in self?.binding?.wrappedValue = newWidth }
    }
}
