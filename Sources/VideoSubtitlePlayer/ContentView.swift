import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = PlayerViewModel()
    @State private var dropTargeted = false

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
                }
                .frame(minWidth: 420, minHeight: 280)

                SubtitleListView(vm: vm)
                    .frame(minWidth: 240, maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            NavigationBarView(vm: vm)
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
            if let url {
                DispatchQueue.main.async { vm.loadVideo(url: url) }
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

    private var current: Subtitle? {
        guard vm.currentSubtitleIndex >= 0, vm.currentSubtitleIndex < vm.subtitles.count else { return nil }
        return vm.subtitles[vm.currentSubtitleIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                controlButtons
                    .padding(.leading, 8)

                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 8)

                navButtons

                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 8)

                subtitleLabel

                Spacer(minLength: 8)

                volumeControl
                    .padding(.trailing, 8)

                positionLabel
                    .padding(.trailing, 12)
            }
            .frame(height: 44)
            .background(.background)
            .overlay(keyboardShortcutButtons)
        }
    }

    private var controlButtons: some View {
        HStack(spacing: 2) {
            NavButton(icon: "stop.fill", label: "停止播放", action: vm.stopVideo, enabled: true)
            NavButton(icon: vm.isPlaying ? "pause.fill" : "play.fill",
                      label: vm.isPlaying ? "暂停 (Space)" : "播放 (Space)",
                      action: vm.togglePlayPause, enabled: true)
        }
    }

    private var navButtons: some View {
        HStack(spacing: 2) {
            NavButton(icon: "backward.end.fill", label: "上一条字幕 (A)", action: vm.previousSubtitle,
                      enabled: !vm.subtitles.isEmpty)
            NavButton(icon: "arrow.counterclockwise", label: "回到当前字幕起点 (S)", action: vm.restartCurrentSubtitle,
                      enabled: vm.currentSubtitleIndex >= 0)
            NavButton(icon: "forward.end.fill", label: "下一条字幕 (D)", action: vm.nextSubtitle,
                      enabled: vm.currentSubtitleIndex < vm.subtitles.count - 1 && !vm.subtitles.isEmpty)
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: vm.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Slider(value: Binding(get: { vm.volume }, set: { vm.setVolume($0) }), in: 0...100)
                .frame(width: 80)
                .controlSize(.mini)
        }
    }

    private var keyboardShortcutButtons: some View {
        ZStack {
            Button("") { vm.previousSubtitle() }.keyboardShortcut("a", modifiers: []).opacity(0)
            Button("") { vm.restartCurrentSubtitle() }.keyboardShortcut("s", modifiers: []).opacity(0)
            Button("") { vm.nextSubtitle() }.keyboardShortcut("d", modifiers: []).opacity(0)
            Button("") { vm.togglePlayPause() }.keyboardShortcut(.space, modifiers: []).opacity(0)
        }
        .frame(width: 0, height: 0)
    }

    private var subtitleLabel: some View {
        Group {
            if let sub = current {
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

struct NavButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    let enabled: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(enabled ? .primary : Color(.tertiaryLabelColor))
        .disabled(!enabled)
        .help(label)
    }
}
