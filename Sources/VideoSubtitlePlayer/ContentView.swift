import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    // Provided by VideoSubtitleApp via .environmentObject(playerVM).
    // Lives at app level so the video/subtitle state survives window close/reopen.
    @EnvironmentObject private var vm: PlayerViewModel
    @State private var dropTargeted = false
    @State private var keyMonitor: Any?
    @State private var showSidebar = true

    var body: some View {
        VStack(spacing: 0) {
            if vm.isVideoLoaded {
                playerLayout
            } else {
                DropZoneView(isTargeted: dropTargeted, onOpen: vm.openFile)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .onReceive(NotificationCenter.default.publisher(for: .openVideoFile)) { _ in
            vm.openFile()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: vm.openFile) {
                    Label("打开视频", systemImage: "folder")
                }
                .help("打开视频文件 (⌘O)")
            }
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
                if let r = NSApp.keyWindow?.firstResponder, r is NSTextView { return event }
                switch event.keyCode {
                case 0:  vm.previousSubtitle();       return nil  // A
                case 1:  vm.restartCurrentSubtitle(); return nil  // S
                case 2:  vm.nextSubtitle();           return nil  // D
                case 49: vm.togglePlayPause();        return nil  // Space
                default: return event
                }
            }
        }
    }

    private var playerLayout: some View {
        VStack(spacing: 0) {
            HSplitView {
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
                    // ── Subtitle overlay ─────────────────────────
                    // Driven by vm.subtitles / currentSubtitleIndex / showSubtitles,
                    // so it automatically reflects track switches and the eye-toggle.
                    videoSubtitleOverlay
                }
                .frame(minWidth: 420, minHeight: 280)

                if showSidebar {
                    SubtitleListView(vm: vm, showSidebar: $showSidebar)
                        .frame(minWidth: 240, maxWidth: 380)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            NavigationBarView(vm: vm, showSidebar: $showSidebar)
        }
    }

    @ViewBuilder
    private var videoSubtitleOverlay: some View {
        if vm.showSubtitles,
           vm.currentSubtitleIndex >= 0,
           vm.currentSubtitleIndex < vm.subtitles.count {
            let text = vm.subtitles[vm.currentSubtitleIndex].cleanText
            if !text.isEmpty {
                VStack {
                    Spacer()
                    Text(text)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black, radius: 1, x: 1, y: 1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.55))
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)
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
    @Binding var showSidebar: Bool
    @State private var copiedFlash = false

    private var current: Subtitle? {
        guard vm.currentSubtitleIndex >= 0, vm.currentSubtitleIndex < vm.subtitles.count else { return nil }
        return vm.subtitles[vm.currentSubtitleIndex]
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
                BarButton(icon: "backward.end.fill", help: "上一条字幕 (A)",
                          disabled: vm.subtitles.isEmpty,
                          action: vm.previousSubtitle)
                BarButton(icon: "arrow.counterclockwise", help: "回到当前字幕起点 (S)",
                          disabled: vm.currentSubtitleIndex < 0,
                          action: vm.restartCurrentSubtitle)
                BarButton(icon: "forward.end.fill", help: "下一条字幕 (D)",
                          disabled: vm.currentSubtitleIndex >= vm.subtitles.count - 1 || vm.subtitles.isEmpty,
                          action: vm.nextSubtitle)

                barDivider

                // ── 字幕开关 ──────────────────────────────────
                BarButton(icon: vm.showSubtitles ? "captions.bubble.fill" : "captions.bubble",
                          help: vm.showSubtitles ? "隐藏字幕（练听力）" : "显示字幕",
                          tint: vm.showSubtitles ? nil : .secondary,
                          action: { vm.showSubtitles.toggle() })

                barDivider

                // ── 字幕文本 + 复制 ───────────────────────────
                subtitleLabel
                copyButton
                    .padding(.horizontal, 4)

                Spacer(minLength: 4)

                // ── 音量 ──────────────────────────────────────
                volumeControl
                    .padding(.trailing, 8)

                // ── 位置 / 侧边栏 ─────────────────────────────
                positionLabel
                    .padding(.trailing, 8)

                BarButton(icon: "sidebar.trailing",
                          help: showSidebar ? "隐藏字幕列表" : "显示字幕列表",
                          tint: showSidebar ? nil : .accentColor,
                          action: { withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() } })
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
            } else if let sub = current {
                Text(sub.cleanText)
                    .font(.system(size: 12.5))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
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
            icon: copiedFlash ? "checkmark" : "doc.on.doc",
            help: "复制当前字幕",
            tint: copiedFlash ? .accentColor : nil,
            disabled: current == nil || !vm.showSubtitles,
            action: {
            guard let text = current?.cleanText, !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedFlash = false }
        })
    }

    private var volumeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: vm.volume < 1 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Slider(value: $vm.volume, in: 0...100)
                .frame(width: 80)
                .controlSize(.mini)
        }
    }

    private var positionLabel: some View {
        Group {
            if !vm.subtitles.isEmpty {
                let pos = vm.currentSubtitleIndex >= 0 ? "\(vm.currentSubtitleIndex + 1)" : "—"
                Text("\(pos) / \(vm.subtitles.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
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
