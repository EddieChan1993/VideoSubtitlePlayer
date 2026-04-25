import SwiftUI

struct SubtitleListView: View {
    @ObservedObject var vm: PlayerViewModel
    @Binding var showSidebar: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if !vm.availableTracks.isEmpty { trackPicker }
            Divider()
            content
        }
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("字幕")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if vm.isLoadingSubtitles {
                HStack(spacing: 5) {
                    ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    Text(vm.loadingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !vm.subtitles.isEmpty {
                Text("\(vm.subtitles.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSidebar = false }
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("隐藏字幕列表")
            .padding(.leading, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Track Picker

    @ViewBuilder
    private var trackPicker: some View {
        let options = buildOptions()
        if !options.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(options, id: \.label) { option in
                        TrackChip(
                            label: option.label,
                            isSelected: option.mode == vm.selectedMode
                        ) {
                            vm.selectMode(option.mode)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            Divider()
        }
    }

    private struct TrackOption {
        let label: String
        let mode: SubtitleMode
    }

    private func buildOptions() -> [TrackOption] {
        let tracks = vm.availableTracks
        guard !tracks.isEmpty else { return [] }

        // 结构固定：单轨选项 + 双语（如有第二轨）
        // 不做去重，不依赖内容检测时机，保证 tab 数量稳定不跳变
        var options: [TrackOption] = []

        // 单轨：只展示第一条（主字幕）
        let primary = tracks[0]
        options.append(TrackOption(label: vm.trackLabel(for: primary), mode: .single(primary)))

        // 双语：有第二条轨道时始终提供
        if tracks.count >= 2 {
            let secondary = tracks[1]
            // 中文在上、英文在下；无法判断时 tracks[0] 为主
            let cn = tracks.first { $0.isChinese }
            let en = tracks.first { $0.isEnglish }
            let (biPrimary, biSecondary): (SubtitleTrack, SubtitleTrack)
            if let cn, let en { (biPrimary, biSecondary) = (cn, en) }
            else {
                let l0 = vm.trackLabel(for: tracks[0])
                let l1 = vm.trackLabel(for: tracks[1])
                (biPrimary, biSecondary) = (l0 == "中文") ? (tracks[0], tracks[1]) : (tracks[1], tracks[0])
            }
            let biLabel = "双语"
            options.append(TrackOption(label: biLabel, mode: .bilingual(biPrimary, biSecondary)))
            _ = secondary // suppress warning
        }

        return options
    }

    // MARK: - Subtitle List

    @ViewBuilder
    private var content: some View {
        if vm.subtitles.isEmpty && !vm.isLoadingSubtitles {
            emptyState
        } else {
            ScrollViewReader { proxy in
                List(vm.subtitles) { sub in
                    SubtitleRow(subtitle: sub, isCurrent: vm.sidebarHighlightIndex == sub.id)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.jumpToSubtitle(sub) }
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .onChange(of: vm.sidebarHighlightIndex) { idx in
                    guard idx >= 0, idx < vm.subtitles.count else { return }
                    if vm.isScrubbing {
                        proxy.scrollTo(idx, anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
                .onChange(of: vm.sidebarScrollTrigger) { _ in
                    let idx = vm.sidebarHighlightIndex
                    guard idx >= 0, idx < vm.subtitles.count else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(vm.availableTracks.isEmpty ? "未找到字幕" : "字幕提取中…")
                .font(.callout)
                .foregroundStyle(.secondary)
            if vm.availableTracks.isEmpty {
                Text("支持 SRT / VTT / ASS 伴随文件\n或视频内嵌字幕轨道")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - TrackChip

struct TrackChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color(.controlBackgroundColor))
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SubtitleRow

struct SubtitleRow: View {
    let subtitle: Subtitle
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(subtitle.startTimeString)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 40, alignment: .trailing)
                .padding(.top, 1)

            Text(subtitle.cleanText)
                .font(.system(size: 12.5))
                .foregroundStyle(isCurrent ? Color.primary : Color(.secondaryLabelColor))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isCurrent ? Color.accentColor.opacity(0.25) : Color.clear, lineWidth: 1)
        )
    }
}
