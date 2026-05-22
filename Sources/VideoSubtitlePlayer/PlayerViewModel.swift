import AVFoundation
import Combine
import SwiftUI

class PlayerViewModel: ObservableObject {
    let player = AVPlayer()

    @Published var subtitles: [Subtitle] = []
    @Published var currentSubtitleIndex: Int = -1
    /// Always holds the index of the last subtitle that was active.
    /// Unlike currentSubtitleIndex it never resets to -1 between subtitles,
    /// so the sidebar can keep the most-recently-seen subtitle highlighted.
    @Published var sidebarHighlightIndex: Int = -1
    @Published var isVideoLoaded = false
    @Published var isLoadingSubtitles = false
    @Published var loadingStatus = ""
    @Published var videoError: String?

    @Published var availableTracks: [SubtitleTrack] = []
    @Published var selectedMode: SubtitleMode? = nil

    @Published var useMPV = false
    @Published var isPlaying = false
    @Published var showSubtitles = true
    @Published var showSidebar = true
    @Published var subtitleCopied = false
    @Published var currentTime: Double = 0
    @Published var videoDuration: Double = 0
    @Published var isScrubbing: Bool = false
    /// track.id → 检测到的语言标签，异步更新后触发 tab 刷新
    @Published var trackLabels: [Int: String] = [:]
    /// 用户拖拽排序后的 chip 顺序（stableId 列表），同步给 orderedModes 让快捷键跟随
    @Published var chipOrder: [String] = []
    /// 当前播放视频的文件名（无扩展名）
    @Published var videoTitle: String = ""
    /// 递增以强制侧边栏滚动到当前字幕（即使 sidebarHighlightIndex 未变化）
    @Published var sidebarScrollTrigger = 0
    @Published var volume: Double = 30 {
        didSet {
            if useMPV { mpvController?.setVolume(volume) }
            else { player.volume = Float(volume / 100.0) }
        }
    }
    @Published private(set) var mpvController: MPVController?

    private(set) var videoURL: URL?
    private var fragStreamer: FragStreamer?
    private var tempVideoURL: URL?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?

    private var subtitleCache: [SubtitleMode: [Subtitle]] = [:]
    private var externalTrackURLs: [Int: URL] = [:]
    private var nextExternalTrackId = -100
    private var extractionTask: Task<Void, Never>?



    init() {
        let interval = CMTime(seconds: 0.08, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.syncCurrentSubtitle(at: time.seconds)
        }
    }

    deinit {
        if let obs = timeObserver { player.removeTimeObserver(obs) }
        mpvController?.stop()
        fragStreamer?.cleanup()
        cleanupTempFile()
    }

    // MARK: - Loading

    func openFile() {
        let panel = NSOpenPanel()
        panel.title = "打开视频"
        panel.message = "选择视频文件（支持 MKV / MP4 / MOV 等格式）"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { loadVideo(url: url) }
    }

    func loadVideo(url: URL) {
        mpvController?.stop()
        mpvController = nil
        useMPV = false
        fragStreamer?.cleanup()
        fragStreamer = nil
        cleanupTempFile()

        videoURL = url
        videoTitle = url.deletingPathExtension().lastPathComponent
        NSApp.mainWindow?.title = videoTitle
        VideoHistory.shared.record(videoURL: url)
        subtitles = []
        availableTracks = []
        selectedMode = nil
        currentSubtitleIndex = -1
        sidebarHighlightIndex = -1
        sidebarScrollTrigger = 0
        videoError = nil
        isVideoLoaded = false   // 先回到初始界面，switchToMPV 成功后再置 true
        isPlaying = false
        isPreparing = false
        isLoadingSubtitles = true
        loadingStatus = "提取字幕中…"
        currentTime = 0
        videoDuration = 0
        trackLabels = [:]
        subtitleCache = [:]
        isScrubbing = false
        externalTrackURLs = [:]
        nextExternalTrackId = -100
        chipOrder = []

        // 后台预生成缩略图，供历史记录弹窗使用（优先级低，不抢 MPV 初始解码）
        let thumbPath = url.path
        Task.detached(priority: .background) {
            await loadVideoThumbnail(path: thumbPath)
        }

        // 取消上一个视频的提取任务，避免旧视频字幕写入新视频侧边栏
        extractionTask?.cancel()
        // 延迟 1.5 秒再启动 FFmpeg 字幕提取，让 MPV 先完成初始解码不争 CPU
        extractionTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            await extractSubtitles(from: url)
        }
        // 下一个 RunLoop tick 再启动播放，让 SwiftUI 先渲染重置状态（isVideoLoaded=false）
        DispatchQueue.main.async { [weak self] in
            self?.playDirectly(url: url)
        }
    }

    @Published var isPreparing = false
    @Published var isConverting = false
    @Published var convertingStatus = ""

    private func playDirectly(url: URL) {
        // Prefer mpv — handles any format natively with no conversion
        if MPVController.isAvailable {
            switchToMPV(url: url)
            return
        }

        // Fallback: try AVFoundation, then fragmented MP4 via FFmpeg
        let item = AVPlayerItem(url: url)
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self, item.status == .failed else { return }
            DispatchQueue.main.async {
                if let ffmpeg = SubtitleExtractor.ffmpegPath {
                    self.streamWithFragMP4(url: url, ffmpegPath: ffmpeg)
                } else {
                    self.videoError = "无法播放此格式，请安装 FFmpeg：\nbrew install ffmpeg"
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        isVideoLoaded = true
        isPlaying = true
    }

    private func switchToMPV(url: URL) {
        player.replaceCurrentItem(with: nil)
        let ctrl = MPVController()
        ctrl.onTimeUpdate = { [weak self] time in
            self?.syncCurrentSubtitle(at: time)
        }
        ctrl.onDuration = { [weak self] dur in
            self?.videoDuration = dur
        }
        // 立即 prepare：加载 libmpv、初始化、开始解码
        // GL 层出现后会自动调用 setupRenderContext，画面就渲染在我们的 View 里
        ctrl.prepare(url: url)
        // 同步音量初始值（MPV 默认音量 100%，与滑块默认 50 不一致）
        ctrl.setVolume(volume)
        mpvController = ctrl
        useMPV = true
        isVideoLoaded = true
        isPlaying = true
    }

    private func streamWithFragMP4(url: URL, ffmpegPath: String) {
        isPreparing = true
        let streamer = FragStreamer()
        fragStreamer = streamer

        Task {
            let output = await streamer.start(url: url, ffmpegPath: ffmpegPath)
            await MainActor.run {
                self.isPreparing = false
                if let output {
                    self.tempVideoURL = output
                    let item = AVPlayerItem(url: output)
                    self.player.replaceCurrentItem(with: item)
                    self.player.play()
                    self.isPlaying = true
                } else {
                    self.videoError = "无法播放此视频格式"
                }
            }
        }
    }

    // MARK: - Subtitle extraction

    private func extractSubtitles(from url: URL) async {
        let (immediateSubs, immediateTracks) = await SubtitleExtractor.extractImmediate(from: url)

        let stillCurrent = await MainActor.run { self.videoURL == url }
        guard !Task.isCancelled, stillCurrent else { return }

        // 立即检测第一条轨道语言，不等预缓存
        let immediateLabel = SubtitleExtractor.languageLabel(from: immediateSubs)

        await MainActor.run {
            self.availableTracks = immediateTracks
            if !immediateSubs.isEmpty {
                if let first = immediateTracks.first {
                    let mode = SubtitleMode.single(first)
                    self.selectedMode = mode
                    self.subtitleCache[mode] = immediateSubs
                    if let label = immediateLabel {
                        self.trackLabels[first.id] = label
                    }
                }
                self.subtitles = immediateSubs
                self.currentSubtitleIndex = -1
                self.isLoadingSubtitles = false
                self.loadingStatus = "已加载 \(immediateSubs.count) 条字幕"
            }
            self.syncChipOrder()
        }

        let labeledTracks = await SubtitleExtractor.listTracksWithLabels(from: url)

        let stillCurrent2 = await MainActor.run { self.videoURL == url }
        guard !Task.isCancelled, stillCurrent2 else { return }

        let companionTracks = SubtitleExtractor.findCompanionTracks(for: url)
        var allTracks = labeledTracks + companionTracks
        if allTracks.isEmpty { allTracks = immediateTracks }

        guard !allTracks.isEmpty else {
            await MainActor.run {
                self.isLoadingSubtitles = false
                self.loadingStatus = "未找到字幕轨道"
            }
            return
        }

        let mode = autoSelectMode(from: allTracks)
        let tracksSnapshot = allTracks

        let needsLoad = await MainActor.run { () -> Bool in
            self.availableTracks = tracksSnapshot
            self.syncChipOrder()
            let changed = self.subtitles.isEmpty || self.selectedMode != mode
            self.selectedMode = mode
            if changed {
                self.isLoadingSubtitles = true
                self.loadingStatus = "提取字幕中…"
            }
            return changed
        }

        if needsLoad { await loadSubtitles(for: mode, url: url) }

        // 延迟 2 秒再缓存其余单轨，避免与 MPV 初始解码争 CPU
        Task {
            try? await Task.sleep(for: .seconds(2))
            await preCacheOtherTracks(tracksSnapshot, url: url, skipMode: mode)
        }
    }

    private func preCacheOtherTracks(_ tracks: [SubtitleTrack], url: URL, skipMode: SubtitleMode) async {
        for track in tracks {
            let mode = SubtitleMode.single(track)
            let alreadyCached = await MainActor.run { self.subtitleCache[mode] != nil }
            guard mode != skipMode, !alreadyCached else { continue }
            let subs = await SubtitleExtractor.extract(from: url, track: track)
            await MainActor.run {
                self.subtitleCache[mode] = subs
                if let label = SubtitleExtractor.languageLabel(from: subs) {
                    self.trackLabels[track.id] = label
                }
            }
        }
    }

    /// 与 selectBilingualTrack 共用的双语 mode 构造逻辑
    func bilingualMode(from tracks: [SubtitleTrack]) -> SubtitleMode {
        let cn = tracks.first { $0.isChinese }
        let en = tracks.first { $0.isEnglish }
        let (p, s): (SubtitleTrack, SubtitleTrack)
        if let cn, let en { (p, s) = (cn, en) }
        else {
            let l0 = trackLabel(for: tracks[0])
            (p, s) = (l0 == "中文") ? (tracks[0], tracks[1]) : (tracks[1], tracks[0])
        }
        return .bilingual(p, s)
    }

    func selectMode(_ mode: SubtitleMode) {
        guard let url = videoURL else { return }
        // 已经在加载同一 mode，忽略重复触发
        if isLoadingSubtitles && selectedMode == mode { return }
        selectedMode = mode

        if let cached = subtitleCache[mode] {
            subtitles = cached
            let time = currentPlaybackTime
            let idx = cached.firstIndex { $0.startTime <= time && $0.endTime > time } ?? -1
            currentSubtitleIndex = idx
            if idx >= 0 {
                sidebarHighlightIndex = idx
            } else if let nearest = cached.lastIndex(where: { $0.startTime <= time }) {
                sidebarHighlightIndex = nearest
            }
            // 字幕一命中缓存就立即更新 tab 标签，不等预缓存延迟
            if case .single(let track) = mode, trackLabels[track.id] == nil,
               let label = SubtitleExtractor.languageLabel(from: cached) {
                trackLabels[track.id] = label
            }
            isLoadingSubtitles = false
            loadingStatus = "已加载 \(cached.count) 条字幕"
            sidebarScrollTrigger += 1
            return
        }

        isLoadingSubtitles = true
        subtitles = []
        currentSubtitleIndex = -1
        sidebarHighlightIndex = -1
        Task { await loadSubtitles(for: mode, url: url) }
    }

    private func autoSelectMode(from tracks: [SubtitleTrack]) -> SubtitleMode {
        // Always start with the first available track.
        // The user can switch to bilingual via the track picker in the sidebar.
        return .single(tracks[0])
    }

    private func loadSubtitles(for mode: SubtitleMode, url: URL) async {
        await MainActor.run { self.loadingStatus = "提取字幕中…" }
        let subs: [Subtitle]
        switch mode {
        case .single(let track):
            if track.id <= -100 {
                subs = externalTrackURLs[track.id].map { SubtitleParser.parse(url: $0) } ?? []
            } else if track.id < 0 {
                subs = SubtitleExtractor.extractCompanion(for: url, track: track)
            } else {
                subs = await SubtitleExtractor.extract(from: url, track: track)
            }
        case .bilingual(let primary, let secondary):
            if primary.id < 0 || secondary.id < 0 {
                let a = SubtitleExtractor.extractCompanion(for: url, track: primary)
                let b = SubtitleExtractor.extractCompanion(for: url, track: secondary)
                subs = SubtitleExtractor.mergeBilingual(a, b)
            } else {
                subs = await SubtitleExtractor.extractBilingual(from: url, primary: primary, secondary: secondary)
            }
        }
        await MainActor.run {
            self.subtitleCache[mode] = subs
            // 字幕加载完成后立即检测语言，更新 tab 标签
            if case .single(let track) = mode, self.trackLabels[track.id] == nil,
               let label = SubtitleExtractor.languageLabel(from: subs) {
                self.trackLabels[track.id] = label
            }
            guard self.selectedMode == mode else { return }
            self.subtitles = subs
            let time = self.currentPlaybackTime
            let idx = subs.firstIndex { $0.startTime <= time && $0.endTime > time } ?? -1
            self.currentSubtitleIndex = idx
            if idx >= 0 {
                self.sidebarHighlightIndex = idx
            } else if let nearest = subs.lastIndex(where: { $0.startTime <= time }) {
                self.sidebarHighlightIndex = nearest
            }
            self.isLoadingSubtitles = false
            self.loadingStatus = subs.isEmpty ? "无字幕内容" : "已加载 \(subs.count) 条字幕"
            self.sidebarScrollTrigger += 1
        }
    }

    // MARK: - Time sync

    /// 记录最新播放时间，供导航函数在字幕间隙时使用
    private var currentPlaybackTime: TimeInterval = 0
    /// 上次推送 currentTime 的墙钟时间（节流用，与播放位置无关）
    private var lastTimePublish: CFTimeInterval = 0
    func syncCurrentSubtitle(at time: TimeInterval) {
        currentPlaybackTime = time

        // currentTime 节流：约 10fps 更新进度条，避免每帧触发 SwiftUI 全量重绘
        let now = CACurrentMediaTime()
        if now - lastTimePublish >= 0.1 || !isPlaying {
            currentTime = time
            lastTimePublish = now
        }
        if !useMPV, let dur = player.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
            videoDuration = dur
        }

        let idx = subtitles.firstIndex { $0.startTime <= time && $0.endTime > time } ?? -1
        if idx != currentSubtitleIndex { currentSubtitleIndex = idx }

        // sidebarHighlightIndex only advances forward — never reverts to -1 between subtitles.
        // This keeps the sidebar showing the last seen entry highlighted.
        if idx >= 0, idx != sidebarHighlightIndex { sidebarHighlightIndex = idx }
    }

    /// 取当前播放位置（AVPlayer 或 MPV 均适用）
    private var now: TimeInterval {
        useMPV ? currentPlaybackTime : player.currentTime().seconds
    }

    // MARK: - Navigation

    func seek(to time: Double) {
        // 立即更新 UI，不等 MPV 的 onTimeUpdate 回调，防止进度条松手后视觉弹回
        currentTime = time
        lastTimePublish = CACurrentMediaTime()
        if let mpv = mpvController {
            mpv.seekExact(to: time)
        } else {
            let t = CMTime(seconds: time, preferredTimescale: 600)
            player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// 拖动进度条时实时更新字幕高亮，不实际 seek 视频
    func previewSubtitleIndex(for time: Double) {
        let idx = subtitles.firstIndex { $0.startTime <= time && $0.endTime > time } ?? -1
        currentSubtitleIndex = idx
        // 拖动时找最近字幕（含间隙）用于侧边栏定位
        if idx >= 0 {
            sidebarHighlightIndex = idx
        } else if let nearest = subtitles.lastIndex(where: { $0.startTime <= time }) {
            sidebarHighlightIndex = nearest
        }
    }

    func jumpToSubtitle(_ subtitle: Subtitle) {
        sidebarHighlightIndex = subtitle.id
        currentTime = subtitle.startTime
        lastTimePublish = CACurrentMediaTime()
        if let mpv = mpvController {
            if !isPlaying { mpv.setPlaying(true); isPlaying = true }
            mpv.seekExact(to: subtitle.startTime)
        } else {
            let t = CMTime(seconds: subtitle.startTime, preferredTimescale: 600)
            player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.player.play()
                self?.isPlaying = true
            }
        }
    }

    func previousSubtitle() {
        guard !subtitles.isEmpty else { return }
        let target: Int
        if currentSubtitleIndex > 0 {
            target = currentSubtitleIndex - 1
        } else if currentSubtitleIndex == 0 {
            target = 0
        } else {
            let locked = sidebarHighlightIndex
            target = locked > 0 ? locked - 1 : 0
        }
        jumpToSubtitle(subtitles[target])
    }

    func restartCurrentSubtitle() {
        restartLockedSubtitle()
    }

    /// 跳回侧边栏锁定字幕（间隙时也可用）
    func restartLockedSubtitle() {
        let idx = sidebarHighlightIndex >= 0 ? sidebarHighlightIndex : currentSubtitleIndex
        guard idx >= 0, idx < subtitles.count else { return }
        jumpToSubtitle(subtitles[idx])
    }

    func nextSubtitle() {
        guard !subtitles.isEmpty else { return }
        if currentSubtitleIndex >= 0 {
            let next = currentSubtitleIndex + 1
            if next < subtitles.count { jumpToSubtitle(subtitles[next]) }
        } else {
            if let target = subtitles.firstIndex(where: { $0.startTime > now }) {
                jumpToSubtitle(subtitles[target])
            }
        }
    }

    func jumpToFirstSubtitle() {
        guard let first = subtitles.first else { return }
        // 00:00 字幕通常是广告，跳过它直接取下一条
        if first.startTime == 0, subtitles.count > 1 {
            jumpToSubtitle(subtitles[1])
        } else {
            jumpToSubtitle(first)
        }
    }

    func jumpToLastSubtitle() {
        guard let last = subtitles.last else { return }
        jumpToSubtitle(last)
    }

    // MARK: - Track label

    /// Returns a display label for a track; falls back to content-based language detection
    /// when the file has no language tag (shows "Track N").
    func trackLabel(for track: SubtitleTrack) -> String {
        if track.isEnglish { return "英文" }
        if track.isChinese { return "中文" }
        if let lang = track.language, !lang.isEmpty { return lang.uppercased() }
        // 用异步检测结果（@Published），稳定更新不引起 tab 数量变化
        if let detected = trackLabels[track.id] { return detected }
        if track.id <= -100 { return "外挂字幕" }
        return "轨道 \(track.index + 1)"
    }

    // MARK: - Playback control

    func modeStableId(_ mode: SubtitleMode) -> String {
        switch mode {
        case .single(let t):           return "s\(t.id)"
        case .bilingual(let p, let s): return "b\(p.id)_\(s.id)"
        }
    }

    /// Raw order derived from availableTracks — each track is its own independent mode.
    private func buildRawModes() -> [SubtitleMode] {
        return availableTracks.map { .single($0) }
    }

    /// Keeps chipOrder in sync with availableTracks (preserves user drag order, appends new, removes deleted).
    func syncChipOrder() {
        let freshIds = buildRawModes().map { modeStableId($0) }
        let freshSet = Set(freshIds)
        var order = chipOrder.filter { freshSet.contains($0) }
        let existing = Set(order)
        order += freshIds.filter { !existing.contains($0) }
        chipOrder = order
    }

    /// Chip order respecting user drag; falls back to track insertion order.
    var orderedModes: [SubtitleMode] {
        let allModes = buildRawModes()
        guard !chipOrder.isEmpty else { return allModes }
        let byId = Dictionary(uniqueKeysWithValues: allModes.map { (modeStableId($0), $0) })
        var result = chipOrder.compactMap { byId[$0] }
        let known = Set(chipOrder)
        result += allModes.filter { !known.contains(modeStableId($0)) }
        return result
    }

    func selectTrackOption(at index: Int) {
        let modes = orderedModes
        guard index < modes.count else { return }
        selectMode(modes[index])
    }

    func selectFirstTrack() { selectTrackOption(at: 0) }
    func selectBilingualTrack() { selectTrackOption(at: 1) }

    func copyCurrentSubtitle() {
        let idx = sidebarHighlightIndex >= 0 ? sidebarHighlightIndex : currentSubtitleIndex
        guard idx >= 0, idx < subtitles.count else { return }
        let text = subtitles[idx].cleanText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        subtitleCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.subtitleCopied = false }
    }

    func togglePlayPause() {
        if useMPV {
            isPlaying.toggle()
            mpvController?.setPlaying(isPlaying)
        } else {
            if player.timeControlStatus == .playing {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
            }
        }
    }

    func stopPlayback() {
        if useMPV {
            mpvController?.seek(to: 0)
            mpvController?.setPlaying(false)
        } else {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            player.pause()
        }
        isPlaying = false
    }

    // MARK: - External subtitle loading

    func openExternalSubtitleFile() {
        guard isVideoLoaded else { return }
        let panel = NSOpenPanel()
        panel.title = "加载字幕文件"
        panel.message = "选择外挂字幕文件（SRT / VTT / ASS / SSA）"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadExternalSubtitle(from: url, autoSelect: true)
    }

    func loadExternalSubtitle(from url: URL, autoSelect: Bool) {
        let ext = url.pathExtension.lowercased()
        guard ["srt", "vtt", "webvtt", "ass", "ssa"].contains(ext) else { return }
        let subs = SubtitleParser.parse(url: url)
        guard !subs.isEmpty else { return }

        let trackId = nextExternalTrackId
        nextExternalTrackId -= 1
        let track = SubtitleTrack(id: trackId, index: 0, language: nil,
                                  title: url.deletingPathExtension().lastPathComponent)
        let mode = SubtitleMode.single(track)

        externalTrackURLs[trackId] = url
        subtitleCache[mode] = subs

        if let label = SubtitleExtractor.languageLabel(from: subs) {
            trackLabels[trackId] = label
        }

        availableTracks.append(track)
        syncChipOrder()
        if autoSelect { selectMode(mode) }

        if let videoURL { VideoHistory.shared.addSubtitle(url, forVideo: videoURL) }
    }

    func loadVideoFromHistory(_ entry: HistoryEntry) {
        guard let url = URL(string: "file://" + entry.videoPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) else { return }
        loadVideo(url: url)
        let paths = entry.externalSubtitlePaths
        guard !paths.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2500))
            for path in paths {
                let subURL = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: path) else { continue }
                loadExternalSubtitle(from: subURL, autoSelect: false)
            }
            // If nothing is showing yet (video has no embedded subs), select the first loaded external track
            if subtitles.isEmpty, let extTrack = availableTracks.first(where: { $0.id <= -100 }) {
                selectMode(.single(extTrack))
            }
        }
    }

    func removeExternalTrack(_ track: SubtitleTrack) {
        guard track.id <= -100 else { return }
        if let url = externalTrackURLs[track.id], let videoURL {
            VideoHistory.shared.removeSubtitle(url.path, forVideo: videoURL)
        }
        externalTrackURLs.removeValue(forKey: track.id)
        trackLabels.removeValue(forKey: track.id)
        subtitleCache.removeValue(forKey: .single(track))
        availableTracks.removeAll { $0.id == track.id }
        syncChipOrder()

        if case .single(let selected) = selectedMode, selected.id == track.id {
            if let first = availableTracks.first {
                selectMode(.single(first))
            } else {
                selectedMode = nil
                subtitles = []
                currentSubtitleIndex = -1
                sidebarHighlightIndex = -1
                isLoadingSubtitles = false
                loadingStatus = "未找到字幕轨道"
            }
        }
    }

    // MARK: - Export

    func exportSubtitlesAsCSV() {
        guard !subtitles.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "导出字幕"
        panel.nameFieldStringValue = (videoTitle.isEmpty ? "subtitles" : videoTitle) + ".csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // UTF-8 BOM ensures Excel opens the file with correct encoding
        var csv = "\u{FEFF}序号,开始时间,结束时间,字幕\n"
        for (i, sub) in subtitles.enumerated() {
            let end = formatExportTime(sub.endTime)
            let text = sub.cleanText
                .replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\n", with: " ")
            csv += "\(i + 1),\(sub.startTimeString),\(end),\"\(text)\"\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }

    private func formatExportTime(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Format warning

    /// Returns the URL to play: renamed .mp4 if user agreed, nil to play original.
    // MARK: - Convert to MKV

    /// 当前有外挂字幕轨道时才显示转换按钮
    var canConvertToMKV: Bool {
        availableTracks.contains { $0.id <= -100 }
    }

    func convertToMKV() {
        guard let videoURL,
              let ffmpeg = SubtitleExtractor.ffmpegPath else { return }

        let extTrackIds = availableTracks.filter { $0.id <= -100 }.map { $0.id }
        let subURLs = extTrackIds.compactMap { externalTrackURLs[$0] }
        guard !subURLs.isEmpty else { return }

        // 确认弹窗
        let confirm = NSAlert()
        confirm.messageText = "转换为内嵌字幕 MKV"
        confirm.informativeText = "将当前视频和外挂字幕合并为一个 MKV 文件，字幕将内嵌其中，播放更流畅精准。"
        confirm.alertStyle = .informational
        confirm.addButton(withTitle: "是，开始转换")
        confirm.addButton(withTitle: "否，取消")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        // 输出路径：同目录，同名，.mkv 后缀；若与原文件同名则加 _embedded
        var outURL = videoURL.deletingPathExtension().appendingPathExtension("mkv")
        if outURL.path == videoURL.path {
            outURL = videoURL.deletingPathExtension()
                .appendingPathExtension("embedded")
                .appendingPathExtension("mkv")
        }

        isConverting = true
        convertingStatus = "正在转换为 MKV…"

        let finalOutURL = outURL
        Task.detached { [weak self] in
            guard let self else { return }

            func run(_ args: [String]) -> (Bool, String) {
                let pipe = Pipe()
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ffmpeg)
                proc.arguments = args
                proc.standardInput  = FileHandle.nullDevice
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError  = pipe
                do {
                    try proc.run()
                } catch {
                    return (false, "ffmpeg 启动失败：\(error.localizedDescription)")
                }
                // 后台读取避免 pipe buffer 满导致死锁
                var errData = Data()
                let g = DispatchGroup()
                g.enter()
                DispatchQueue.global().async {
                    errData = pipe.fileHandleForReading.readDataToEndOfFile()
                    g.leave()
                }
                proc.waitUntilExit()
                g.wait()
                let errMsg = String(data: errData, encoding: .utf8) ?? String(data: errData, encoding: .isoLatin1) ?? ""
                print("[run] status=\(proc.terminationStatus) errBytes=\(errData.count)")
                return (proc.terminationStatus == 0, errMsg)
            }

            // 将字幕文件标准化为 ffmpeg 可接受的格式：
            // 1. GBK/BOM → UTF-8  2. 统一 \n 行尾  3. 规范化时间戳格式并删除零时长条目
            var tempSubFiles: [URL] = []

            func padSRTTime(_ t: String) -> String {
                let colonParts = t.components(separatedBy: ":")
                guard colonParts.count == 3 else { return t }
                let h = String(format: "%02d", Int(colonParts[0]) ?? 0)
                let m = String(format: "%02d", Int(colonParts[1]) ?? 0)
                let msParts = colonParts[2].components(separatedBy: ",")
                guard msParts.count == 2 else { return t }
                let s = String(format: "%02d", Int(msParts[0]) ?? 0)
                return "\(h):\(m):\(s),\(msParts[1])"
            }

            // 将"English text. 中文文字。"拆成两行，让 mergeBilingual 行级去重正确剥离英文
            func splitMixedLine(_ line: String) -> [String] {
                var splitIdx: String.Index? = nil
                for idx in line.indices {
                    let scalar = line[idx].unicodeScalars.first!.value
                    if scalar >= 0x4E00 && scalar <= 0x9FFF { splitIdx = idx; break }
                }
                guard let idx = splitIdx else { return [line] }
                let before = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
                let after  = String(line[idx...]).trimmingCharacters(in: .whitespaces)
                guard !before.isEmpty, !after.isEmpty else { return [line] }
                return [before, after]
            }

            func normalizeSRT(_ raw: String) -> String {
                var out = ""
                var idx = 1
                // 按空行切块，兼容多余空行
                let blocks = raw.components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                for block in blocks {
                    let lines = block.components(separatedBy: "\n")
                    guard let tsLineIdx = lines.firstIndex(where: { $0.contains("-->") })
                    else { continue }
                    // 规范化时间戳
                    let rawTS = lines[tsLineIdx]
                        .replacingOccurrences(of: "-->", with: " --> ")
                        .replacingOccurrences(of: "  --> ", with: " --> ")
                    let tsParts = rawTS.components(separatedBy: " --> ")
                    guard tsParts.count == 2 else { continue }
                    let start = padSRTTime(tsParts[0].trimmingCharacters(in: .whitespaces))
                    var end   = padSRTTime(tsParts[1].trimmingCharacters(in: .whitespaces))
                    // 零时长条目：ffmpeg 无法处理 start==end，赋予 2 秒合成时长而非丢弃
                    if start == end {
                        let parts = end.components(separatedBy: CharacterSet(charactersIn: ":,"))
                        if parts.count == 4,
                           let h = Int(parts[0]), let m = Int(parts[1]),
                           let s = Int(parts[2]), let ms = Int(parts[3]) {
                            var totalMs = (h * 3600 + m * 60 + s) * 1000 + ms + 2000
                            let newMs = totalMs % 1000; totalMs /= 1000
                            let newS  = totalMs % 60;  totalMs /= 60
                            let newM  = totalMs % 60;  totalMs /= 60
                            end = String(format: "%02d:%02d:%02d,%03d", totalMs, newM, newS, newMs)
                        }
                    }
                    let textLines = lines[(tsLineIdx + 1)...]
                        .filter { !$0.isEmpty }
                        .flatMap { splitMixedLine($0) }   // 英中同行 → 拆成两行
                    guard !textLines.isEmpty else { continue }
                    out += "\(idx)\n\(start) --> \(end)\n\(textLines.joined(separator: "\n"))\n\n"
                    idx += 1
                }
                return out
            }

            func prepareSubtitle(_ url: URL) -> String {
                guard let data = try? Data(contentsOf: url) else { return "file:\(url.path)" }
                let gbkEnc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
                var str: String
                if var s = String(data: data, encoding: .utf8) {
                    if s.hasPrefix("\u{FEFF}") { s = String(s.dropFirst()) }
                    str = s
                } else if var s = String(data: data, encoding: gbkEnc) {
                    if s.hasPrefix("\u{FEFF}") { s = String(s.dropFirst()) }
                    str = s
                } else {
                    return "file:\(url.path)"
                }
                str = str.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r", with: "\n")
                str = normalizeSRT(str)
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".srt")
                guard (try? str.write(to: tmp, atomically: true, encoding: .utf8)) != nil else {
                    return "file:\(url.path)"
                }
                tempSubFiles.append(tmp)
                print("[sub] \(url.lastPathComponent) → 标准化 UTF-8 临时文件")
                return tmp.path
            }
            let preparedSubPaths = subURLs.map { prepareSubtitle($0) }

            // 构建 ffmpeg 输入和 map 参数：input 0 = 视频，input 1..N = 字幕
            // 视频路径用 file: 前缀处理 [ ] 等特殊字符；字幕已为临时文件，直接用绝对路径
            func buildArgs(videoCodec: String, audioCodec: String) -> [String] {
                var args = ["-y", "-i", "file:\(videoURL.path)"]
                for path in preparedSubPaths { args += ["-i", path] }
                args += ["-map", "0"]
                for i in 1...preparedSubPaths.count { args += ["-map", "\(i):0"] }
                args += ["-c:v", videoCodec, "-c:a", audioCodec, "-c:s", "srt", "file:\(finalOutURL.path)"]
                return args
            }

            // 第一步：尝试直接封装（不重编码，速度快）
            let copyArgs = buildArgs(videoCodec: "copy", audioCodec: "copy")
            print("[ffmpeg] \(ffmpeg) \(copyArgs.joined(separator: " "))")
            let (copySuccess, copyErr) = run(copyArgs)
            print("[ffmpeg] copy 结束，success=\(copySuccess)\n--- err tail ---\n\(copyErr.suffix(800))\n---")

            // 第一步失败（如 rv30 等编码不兼容 MKV）→ 询问是否重新编码
            let finalSuccess: Bool
            if copySuccess {
                finalSuccess = true
            } else {
                let reencode: Bool = await MainActor.run {
                    let ask = NSAlert()
                    ask.messageText = "直接封装失败"
                    ask.informativeText = "当前视频编码不兼容 MKV 容器，需要重新编码（H.264 + AAC）。\n重新编码耗时较长，是否继续？"
                    ask.alertStyle = .warning
                    ask.addButton(withTitle: "重新编码")
                    ask.addButton(withTitle: "取消")
                    return ask.runModal() == .alertFirstButtonReturn
                }
                if reencode {
                    await MainActor.run { self.convertingStatus = "正在重新编码，请耐心等待…" }
                    print("[ffmpeg] 开始重新编码 libx264…")
                    let (reSuccess, reErr) = run(buildArgs(videoCodec: "libx264", audioCodec: "aac"))
                    print("[ffmpeg] 重新编码结束，success=\(reSuccess)\n--- err tail ---\n\(reErr.suffix(800))\n---")
                    if !reSuccess {
                        await MainActor.run {
                            let err = NSAlert()
                            err.messageText = "重新编码失败"
                            err.informativeText = reErr.suffix(300).description
                            err.alertStyle = .warning
                            err.runModal()
                        }
                    }
                    finalSuccess = reSuccess
                } else {
                    finalSuccess = false
                }
            }

            tempSubFiles.forEach { try? FileManager.default.removeItem(at: $0) }

            await MainActor.run {
                self.isConverting = false
                self.convertingStatus = ""

                if finalSuccess {
                    let done = NSAlert()
                    done.messageText = "转换完成"
                    done.informativeText = "已生成：\(finalOutURL.path)\n\n是否切换到新视频继续播放？"
                    done.alertStyle = .informational
                    done.addButton(withTitle: "切换到新视频")
                    done.addButton(withTitle: "继续使用原视频")
                    if done.runModal() == .alertFirstButtonReturn {
                        self.loadVideo(url: finalOutURL)
                    }
                }
            }
        }
    }

    // MARK: - Go Home

    func goHome() {
        extractionTask?.cancel()
        extractionTask = nil
        mpvController?.stop()
        mpvController = nil
        useMPV = false
        player.replaceCurrentItem(with: nil)
        fragStreamer?.cleanup()
        fragStreamer = nil
        cleanupTempFile()

        videoURL = nil
        videoTitle = ""
        subtitles = []
        availableTracks = []
        selectedMode = nil
        currentSubtitleIndex = -1
        sidebarHighlightIndex = -1
        sidebarScrollTrigger = 0
        videoError = nil
        isVideoLoaded = false
        isPlaying = false
        isPreparing = false
        isLoadingSubtitles = false
        loadingStatus = ""
        currentTime = 0
        videoDuration = 0
        trackLabels = [:]
        subtitleCache = [:]
        isScrubbing = false
        externalTrackURLs = [:]
        nextExternalTrackId = -100
        chipOrder = []
    }

    // MARK: - Cleanup

    private func cleanupTempFile() {
        if let tmp = tempVideoURL {
            try? FileManager.default.removeItem(at: tmp)
            tempVideoURL = nil
        }
    }
}
