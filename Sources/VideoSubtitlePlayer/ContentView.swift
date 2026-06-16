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
    @State private var showTranscribePanel = false

    var body: some View {
        VStack(spacing: 0) {
            if vm.isVideoLoaded {
                playerLayout
            } else {
                homeLayout
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .onChange(of: vm.videoTitle) { _, title in
            NSApp.mainWindow?.title = title.isEmpty ? "SubMelon" : title
        }
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
                ToolbarItem(placement: .navigation) {
                    Button {
                        showHistory.toggle()
                    } label: {
                        Label("最近播放", systemImage: "clock")
                    }
                    .help("最近播放记录")
                    .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                        HistoryPopoverView(history: VideoHistory.shared) { entry in
                            vm.loadVideoFromHistory(entry)
                            showHistory = false
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: vm.convertToMKV) {
                        Label("内嵌字幕", systemImage: "arrow.down.doc")
                    }
                    .help("将外挂字幕内嵌进视频，生成 MKV 文件")
                    .disabled(!vm.canConvertToMKV)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showTranscribePanel.toggle()
                    } label: {
                        Label("语音转字幕", systemImage: "waveform.badge.microphone")
                    }
                    .help("使用 Whisper 将视频音频识别为字幕")
                    .popover(isPresented: $showTranscribePanel, arrowEdge: .bottom) {
                        TranscribeSettingsView(vm: vm, isPresented: $showTranscribePanel)
                    }
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
            // 窗口重新出现时恢复标题（onChange 在值未变时不触发）
            NSApp.mainWindow?.title = vm.videoTitle.isEmpty ? "SubMelon" : vm.videoTitle
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
                    if vm.isConverting {
                        convertingOverlay
                    }
                    if vm.isTranscribing {
                        transcribingOverlay
                    }
                    seekBarOverlay
                }
                .frame(minWidth: 420, minHeight: 280)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture(count: 2) {
                    guard vm.isVideoLoaded else { return }
                    vm.togglePlayPause()
                }

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

    private var convertingOverlay: some View {
        VStack {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text(vm.convertingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 12)
            Spacer()
        }
    }

    private var transcribingOverlay: some View {
        VStack {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text(vm.transcribeStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TranscribeCancelButton { vm.cancelTranscribeAudio() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 12)
            Spacer()
        }
    }

    private struct TranscribeCancelButton: View {
        let action: () -> Void
        @State private var hovering = false
        @State private var pressing = false

        var body: some View {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hovering ? Color.white : Color.secondary)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(hovering
                              ? (pressing ? Color.red.opacity(0.75) : Color.red.opacity(0.85))
                              : Color.secondary.opacity(0.2))
                )
                .scaleEffect(pressing ? 0.88 : 1.0)
                .animation(.spring(duration: 0.15), value: hovering)
                .animation(.spring(duration: 0.1), value: pressing)
                .contentShape(Circle())
                .onHover { h in
                    hovering = h
                    if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in pressing = true }
                        .onEnded   { _ in pressing = false; action() }
                )
                .help("取消识别")
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
            guard let url else { return }
            let subtitleExts: Set<String> = ["srt", "vtt", "webvtt", "ass", "ssa"]
            DispatchQueue.main.async {
                if subtitleExts.contains(url.pathExtension.lowercased()) {
                    vm.loadExternalSubtitle(from: url, autoSelect: true)
                } else {
                    vm.loadVideo(url: url)
                }
            }
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
    @State private var showClearConfirm = false

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
                showClearConfirm = true
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
                if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .confirmationDialog("确定清空全部播放记录？", isPresented: $showClearConfirm) {
                Button("清空全部", role: .destructive) { history.clearAll() }
                Button("取消", role: .cancel) {}
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
    @State private var showClearConfirm = false

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
                    showClearConfirm = true
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
                    if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
                .confirmationDialog("确定清空全部播放记录？", isPresented: $showClearConfirm) {
                    Button("清空全部", role: .destructive) { history.clearAll() }
                    Button("取消", role: .cancel) {}
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
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
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
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
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

// MARK: - Transcribe Settings Popover

struct TranscribeSettingsView: View {
    @ObservedObject var vm: PlayerViewModel
    @Binding var isPresented: Bool          // 用于文件选择后重新弹出
    @AppStorage("whisper.modelPath")   private var modelPath:       String = ""
    @AppStorage("whisper.bilingual")   private var enableBilingual: Bool   = false
    @AppStorage("whisper.sourceLang")  private var sourceLang:      String = "en"
    @AppStorage("whisper.targetLang")  private var targetLang:      String = "zh"
    @State private var showFilePicker = false
    @Environment(\.dismiss) private var dismiss

    private let langOptions: [(code: String, name: String)] = [
        ("en", "英文"), ("zh", "中文"), ("ja", "日文"),
        ("ko", "韩文"), ("fr", "法文"), ("de", "德文"), ("es", "西班牙文")
    ]
    private var modelFileName: String {
        modelPath.isEmpty ? "" : URL(fileURLWithPath: modelPath).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("语音转字幕").font(.headline)
            Divider()

            // ── 模型行（点击 chip 文字区域可更换模型）────────────────
            HStack(spacing: 8) {
                // 链接 icon → 打开 Whisper 模型官方下载页
                Button {
                    NSWorkspace.shared.open(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/tree/main")!)
                } label: {
                    Image(systemName: "link.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("点击打开 Whisper 模型官方下载页")
                .onHover { h in if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }

                Text("Whisper 模型").font(.callout).foregroundStyle(.primary)
                Spacer()
                if modelPath.isEmpty {
                    Button(action: { showFilePicker = true }) {
                        Text("点击导入…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(Color(.controlBackgroundColor)))
                    }
                    .buttonStyle(.plain)
                    .onHover { h in if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
                } else {
                    TranscribeModelChip(name: modelFileName,
                                        onReplace: { showFilePicker = true },
                                        onRemove:  { vm.removeWhisperModel() })
                }
            }

            // ── 双语字幕（macOS 26+ Translation 框架）────────────────
            if #available(macOS 26, *) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("生成双语字幕", isOn: $enableBilingual)
                        .toggleStyle(.checkbox).font(.callout)
                    if enableBilingual {
                        HStack(spacing: 8) {
                            Picker("", selection: $sourceLang) {
                                ForEach(langOptions, id: \.code) { Text($0.name).tag($0.code) }
                            }.labelsHidden().frame(width: 80).controlSize(.small)
                            Text("译为").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $targetLang) {
                                ForEach(langOptions, id: \.code) { Text($0.name).tag($0.code) }
                            }.labelsHidden().frame(width: 80).controlSize(.small)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            // ── 操作按钮（全宽）──────────────────────────────────────
            TranscribePopoverButton(
                "开始识别",
                isPrimary: true,
                disabled: modelPath.isEmpty || vm.isTranscribing,
                fullWidth: true
            ) {
                dismiss()
                if #available(macOS 26, *) {
                    vm.transcribeAudio(bilingual: enableBilingual, sourceLang: sourceLang, targetLang: targetLang)
                } else {
                    vm.transcribeAudio()
                }
            }

        }
        .padding(16)
        .frame(width: 310)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "bin") ?? .data]
        ) { result in
            if case .success(let url) = result {
                vm.whisperModelPath = url.path
                vm.objectWillChange.send()
            }
            // macOS 上 NSOpenPanel 会让 popover 失焦关闭；选完后重新弹出
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isPresented = true
            }
        }
    }
}

// 模型文件名 Chip（带 ✕ 移除）
private struct TranscribeModelChip: View {
    let name: String
    let onReplace: () -> Void
    let onRemove: () -> Void
    @State private var xHover = false

    var body: some View {
        HStack(spacing: 5) {
            // 点击图标+文字区域 → 更换模型
            Button(action: onReplace) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(name).font(.system(size: 11.5, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("点击更换模型")
            .onHover { h in if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }

            // X → 删除模型
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(xHover ? Color.primary : Color.secondary)
                .padding(3)
                .background(Circle().fill(xHover ? Color(.controlColor) : Color.clear))
                .contentShape(Circle().inset(by: -2))
                .onHover { h in xHover = h; if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
                .onTapGesture { onRemove() }
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Color(.controlBackgroundColor)))
    }
}

// 带 hover / press 效果的通用弹窗按钮
struct TranscribePopoverButton: View {
    let label: String
    var isPrimary: Bool  = false
    var disabled: Bool   = false
    var fullWidth: Bool  = false
    let action: () -> Void
    @State private var isHovered = false

    init(_ label: String, isPrimary: Bool = false, disabled: Bool = false, fullWidth: Bool = false, action: @escaping () -> Void) {
        self.label = label; self.isPrimary = isPrimary; self.disabled = disabled; self.fullWidth = fullWidth; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: isPrimary ? .semibold : .regular))
                .foregroundStyle(fgColor)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(bgColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isPrimary ? Color.clear : Color(.separatorColor).opacity(0.5), lineWidth: 0.5)
                )
        }
        .buttonStyle(PressScaleStyle())
        .disabled(disabled)
        .onHover { h in
            isHovered = !disabled && h
            if h && !disabled { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    private var fgColor: Color {
        disabled ? Color(.tertiaryLabelColor) : (isPrimary ? .white : .primary)
    }
    private var bgColor: Color {
        if disabled { return Color(.controlBackgroundColor).opacity(0.5) }
        if isPrimary { return isHovered ? Color.accentColor.opacity(0.82) : Color.accentColor }
        return isHovered ? Color(.controlColor) : Color(.controlBackgroundColor)
    }
}
