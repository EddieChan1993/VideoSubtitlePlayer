import SwiftUI

struct SubtitleListView: View {
    @ObservedObject var vm: PlayerViewModel
    @State private var draggedChipId: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 4) {
            // 轨道 Chip 横向滚动区，支持拖拽排序
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    let options = orderedOptions
                    if options.isEmpty {
                        Text("字幕")
                            .font(.subheadline.weight(.semibold))
                    } else {
                        ForEach(Array(options.enumerated()), id: \.element.stableId) { idx, option in
                            TrackChip(
                                label: option.label,
                                isSelected: option.mode == vm.selectedMode,
                                action: { vm.selectMode(option.mode) },
                                onRemove: option.removeTrack.map { track in
                                    option.isExternal
                                        ? { vm.removeExternalTrack(track) }
                                        : { vm.removeBuiltInTrack(track) }
                                }
                            )
                            .fixedSize()
                            .help("\(option.label) (\(idx + 1))")
                            .opacity(draggedChipId == option.stableId ? 0.4 : 1.0)
                            .onDrag {
                                draggedChipId = option.stableId
                                return NSItemProvider(object: option.stableId as NSString)
                            }
                            .onDrop(of: [.text], delegate: ChipDropDelegate(
                                targetId: option.stableId,
                                order: Binding(get: { self.vm.chipOrder },
                                               set: { self.vm.chipOrder = $0 }),
                                draggedId: $draggedChipId
                            ))
                        }
                    }
                    if vm.isVideoLoaded {
                        HoverIconButton(systemName: "plus.circle", help: "加载外挂字幕文件（SRT / VTT / ASS）") {
                            vm.openExternalSubtitleFile()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .animation(.easeInOut(duration: 0.2), value: vm.chipOrder)
            }

            // 右侧固定区：进度 / 计数 + 折叠按钮
            if vm.isLoadingSubtitles {
                HStack(spacing: 5) {
                    ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    Text(vm.loadingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !vm.subtitles.isEmpty {
                let pos = vm.sidebarHighlightIndex >= 0 ? "\(vm.sidebarHighlightIndex + 1)" : "—"
                Text("\(pos) / \(vm.subtitles.count) 条")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            HoverIconButton(systemName: "sidebar.trailing", help: "隐藏字幕列表") {
                withAnimation(.easeInOut(duration: 0.2)) { vm.showSidebar = false }
            }
            .padding(.trailing, 12)
            .padding(.leading, 2)
        }
        .padding(.vertical, 8)
    }

    // Chips ordered by user's drag preference (vm.chipOrder); new tracks appended at end
    private var orderedOptions: [TrackOption] {
        let fresh = buildOptions()
        guard !vm.chipOrder.isEmpty else { return fresh }
        let byId = Dictionary(uniqueKeysWithValues: fresh.map { ($0.stableId, $0) })
        var result = vm.chipOrder.compactMap { byId[$0] }
        let known = Set(vm.chipOrder)
        result += fresh.filter { !known.contains($0.stableId) }
        return result
    }

    private struct ChipDropDelegate: DropDelegate {
        let targetId: String
        @Binding var order: [String]
        @Binding var draggedId: String?

        func dropEntered(info: DropInfo) {
            guard let from = draggedId, from != targetId,
                  let fi = order.firstIndex(of: from),
                  let ti = order.firstIndex(of: targetId) else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                order.move(fromOffsets: IndexSet(integer: fi), toOffset: ti > fi ? ti + 1 : ti)
            }
        }
        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
        func performDrop(info: DropInfo) -> Bool { draggedId = nil; return true }
    }

    private struct TrackOption {
        let label: String
        let mode: SubtitleMode
        var removeTrack: SubtitleTrack? = nil
        var isExternal: Bool = true

        // Stable key derived from track IDs, not from the label which can change asynchronously
        var stableId: String {
            switch mode {
            case .single(let t):          return "s\(t.id)"
            case .bilingual(let p, let s): return "b\(p.id)_\(s.id)"
            }
        }
    }

    private func buildOptions() -> [TrackOption] {
        let tracks = vm.availableTracks
        guard !tracks.isEmpty else { return [] }

        var options: [TrackOption] = []

        let builtInTracks  = tracks.filter { $0.id > -100 }
        let externalTracks = tracks.filter { $0.id <= -100 }

        // 收集外挂字幕的标签集合，用于检测名称冲突
        let externalLabels = Set(externalTracks.map { vm.trackLabel(for: $0) })

        // 内置轨道：始终带删除按钮；若与外挂字幕同名则加 "(内置)" 后缀
        for track in builtInTracks {
            let base  = vm.trackLabel(for: track)
            let label = externalLabels.contains(base) ? "\(base)（内置）" : base
            options.append(TrackOption(label: label, mode: .single(track),
                                       removeTrack: track, isExternal: false))
        }

        // 外挂字幕（id <= -100）：带删除按钮
        for track in externalTracks {
            options.append(TrackOption(label: vm.trackLabel(for: track), mode: .single(track),
                                       removeTrack: track, isExternal: true))
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
                        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 20))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .onAppear {
                    let idx = vm.sidebarHighlightIndex
                    guard idx >= 0, idx < vm.subtitles.count else { return }
                    // Defer until List has finished layout; immediate scroll lands at wrong offset
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
                .onChange(of: vm.sidebarHighlightIndex) { _, idx in
                    guard idx >= 0, idx < vm.subtitles.count else { return }
                    if vm.isScrubbing {
                        proxy.scrollTo(idx, anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
                .onChange(of: vm.sidebarScrollTrigger) { _, _ in
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
                if vm.isVideoLoaded {
                    Button("加载字幕文件…") {
                        vm.openExternalSubtitleFile()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
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
    var onRemove: (() -> Void)? = nil

    @State private var xHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
            if let onRemove {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isSelected
                        ? (xHovering ? Color.white : Color.white.opacity(0.65))
                        : (xHovering ? Color.primary : Color.secondary))
                    .padding(3)
                    .background(
                        Circle().fill(xHovering
                            ? (isSelected ? Color.white.opacity(0.25) : Color(.controlColor))
                            : Color.clear)
                    )
                    .contentShape(Circle().inset(by: -2))
                    .onHover { h in
                        xHovering = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    .onTapGesture { onRemove() }
            }
        }
        .padding(.horizontal, onRemove != nil ? 8 : 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(isSelected ? Color.accentColor : Color(.controlBackgroundColor)))
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .contentShape(Capsule())
        .onTapGesture { action() }
        .onHover { h in
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

// MARK: - HoverIconButton

struct HoverIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13))
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? Color(.controlColor) : Color.clear)
            )
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
            .onHover { h in
                hovering = h
                if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .onTapGesture { action() }
            .help(help)
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
