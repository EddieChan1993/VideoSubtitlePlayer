import AVFoundation
import Combine
import SwiftUI
#if canImport(Translation)
import Translation
#endif

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
    @Published var volume: Double = {
        let saved = UserDefaults.standard.double(forKey: "player.volume")
        return saved > 0 ? saved : 30
    }() {
        didSet {
            UserDefaults.standard.set(volume, forKey: "player.volume")
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
    @Published var isTranscribing = false
    @Published var transcribeStatus = ""

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

    /// 从显示列表移除内置字幕轨道（不修改视频文件，只清空 app 内的轨道/缓存）
    func removeBuiltInTrack(_ track: SubtitleTrack) {
        guard track.id > -100 else { return }
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

    // MARK: - Transcribe (whisper-cli / whisper.cpp)

    /// whisper-cli 可执行文件路径（whisper.cpp，brew install whisper-cpp）
    static let whisperPath: String? = {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }()

    /// 用户手动导入的 ggml .bin 模型文件路径（持久化到 UserDefaults）
    var whisperModelPath: String {
        get { UserDefaults.standard.string(forKey: "whisper.modelPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "whisper.modelPath") }
    }

    /// 仅文件名，用于显示
    var whisperModelFileName: String {
        let p = whisperModelPath
        guard !p.isEmpty else { return "" }
        return URL(fileURLWithPath: p).lastPathComponent
    }

    /// 弹出文件选择器，让用户导入 ggml .bin 模型文件（不拷贝，直接记录路径）
    func importWhisperModel() {
        let panel = NSOpenPanel()
        panel.title = "选择 Whisper 模型文件"
        panel.message = "请选择 ggml-tiny / ggml-small / ggml-medium / ggml-large 等 .bin 格式文件"
        panel.allowedContentTypes = [.init(filenameExtension: "bin") ?? .data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        whisperModelPath = url.path
        objectWillChange.send()
    }

    /// 移除当前记录的模型（不删除文件，只清空路径）
    func removeWhisperModel() {
        whisperModelPath = ""
        objectWillChange.send()
    }

    func transcribeAudio(bilingual: Bool = false, sourceLang: String = "en", targetLang: String = "zh") {
        guard let videoURL else { return }
        guard let whisperCLI = PlayerViewModel.whisperPath else {
            let a = NSAlert()
            a.messageText = "未找到 whisper-cli"
            a.informativeText = "请先安装：brew install whisper-cpp"
            a.alertStyle = .warning
            a.runModal()
            return
        }
        guard let ffmpeg = SubtitleExtractor.ffmpegPath else { return }
        let modelPath = whisperModelPath
        guard !modelPath.isEmpty else { return }

        let outDir  = videoURL.deletingLastPathComponent()
        let stem    = videoURL.deletingPathExtension().lastPathComponent
        // 使用 .asr.srt 后缀而非 .srt，避免被 findCompanionTracks 当作内置伴随字幕重复加载
        let outSRT  = outDir.appendingPathComponent(stem + ".asr.srt")
        // whisper-cli 只接受 WAV，先用 ffmpeg 提取为 16kHz 单声道
        let tempWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")

        isTranscribing = true
        transcribeStatus = "正在提取音频…"

        Task { [weak self] in
            guard let self else { return }

            // success 携带实际找到的 SRT 路径（whisper-cli 有时附加语言码，如 stem.en.srt）
            enum WhisperResult { case success(URL); case failed(String) }

            // 辅助：在同步上下文运行子进程并返回（退出码, stderr）
            func runSync(_ exe: String, _ args: [String]) -> (Int32, String) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let outPipe = Pipe(), errPipe = Pipe()
                p.standardOutput = outPipe; p.standardError = errPipe
                let errBox = DataBox()
                let g = DispatchGroup()
                g.enter(); DispatchQueue.global().async { errBox.append(errPipe.fileHandleForReading.readDataToEndOfFile()); g.leave() }
                g.enter(); DispatchQueue.global().async { _ = outPipe.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                guard (try? p.run()) != nil else { g.wait(); return (-1, "launch failed") }
                p.waitUntilExit(); g.wait()
                return (p.terminationStatus, String(data: errBox.data, encoding: .utf8) ?? "")
            }

            let result: WhisperResult = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { try? FileManager.default.removeItem(at: tempWAV) }

                    // Step 1: 提取 16kHz 单声道 WAV
                    let (audioCode, audioErr) = runSync(ffmpeg, [
                        "-y", "-i", videoURL.path,
                        "-vn", "-ar", "16000", "-ac", "1", "-f", "wav",
                        tempWAV.path
                    ])
                    guard audioCode == 0 else {
                        continuation.resume(returning: .failed("音频提取失败：\(audioErr.suffix(200))"))
                        return
                    }

                    // 更新状态提示
                    DispatchQueue.main.async { [self] in
                        self.transcribeStatus = "语音识别中，请稍候（可能需要数分钟）…"
                    }

                    // Step 2: whisper-cli 识别
                    // 输出前缀使用 stem.asr（不含最终扩展名），生成 stem.asr.srt
                    // 避免与 findCompanionTracks 的 stem.srt 命名冲突，防止重复加载
                    let outPrefix = outSRT.deletingPathExtension().path
                    let (wCode, wErr) = runSync(whisperCLI, [
                        "-m", modelPath,
                        "-f", tempWAV.path,
                        "-osrt",
                        "-of", outPrefix
                    ])

                    guard wCode == 0 else {
                        continuation.resume(returning: .failed(wErr.isEmpty ? "whisper-cli 异常退出（code \(wCode)）" : String(wErr.suffix(500))))
                        return
                    }

                    // 优先检查预期路径 stem.asr.srt；
                    // whisper-cli 某些版本会再附加语言码（如 stem.asr.en.srt），做 fallback 扫描
                    if FileManager.default.fileExists(atPath: outSRT.path) {
                        continuation.resume(returning: .success(outSRT))
                        return
                    }
                    let outPrefixName = outSRT.deletingPathExtension().lastPathComponent.lowercased()
                    let items = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []
                    if let found = items.first(where: { name in
                        let lower = name.lowercased()
                        return lower.hasSuffix(".srt") && lower.hasPrefix(outPrefixName)
                    }) {
                        continuation.resume(returning: .success(outDir.appendingPathComponent(found)))
                    } else {
                        continuation.resume(returning: .failed("识别完成但未找到输出 SRT 文件（已检查目录：\(outDir.path)）\n\n whisper-cli 输出：\(wErr.suffix(300))"))
                    }
                }
            }

            switch result {
            case .failed(let err):
                await MainActor.run {
                    self.isTranscribing = false
                    self.transcribeStatus = ""
                    let a = NSAlert()
                    a.messageText = "语音识别失败"
                    a.informativeText = err
                    a.alertStyle = .warning
                    a.runModal()
                }

            case .success(let actualSRT):
                // 翻译生成双语 SRT
                var bilingualURL: URL? = nil
                var translateError: String? = nil
                if bilingual {
                    await MainActor.run { self.transcribeStatus = "正在翻译字幕…" }
                    if #available(macOS 26, *) {
                        (bilingualURL, translateError) = await self.translateSRT(
                            at: actualSRT, sourceLang: sourceLang, targetLang: targetLang)
                    } else {
                        translateError = "双语翻译需要 macOS 26 或更高版本"
                    }
                }
                // 用本地常量捕获，避免 Swift 6 对 var 的跨并发引用警告
                let finalBilingualURL = bilingualURL
                let finalTranslateError = translateError
                await MainActor.run {
                    self.isTranscribing = false
                    self.transcribeStatus = ""
                    // 仅在当前没有字幕显示时才 autoSelect，避免覆盖用户正在看的双语/其他轨道
                    let noSubtitleNow = self.selectedMode == nil || self.subtitles.isEmpty
                    // 原始字幕先加载
                    self.loadExternalSubtitle(from: actualSRT,
                                              autoSelect: noSubtitleNow && finalBilingualURL == nil)
                    // 双语字幕加载（如果当前有字幕也不强制切换）
                    if let url = finalBilingualURL {
                        self.loadExternalSubtitle(from: url, autoSelect: noSubtitleNow)
                    }
                    // 在 Finder 中定位生成的 SRT 文件，方便用户找到
                    NSWorkspace.shared.activateFileViewerSelecting([actualSRT])

                    // 双语翻译失败时提示原因
                    if bilingual, finalBilingualURL == nil, let err = finalTranslateError {
                        let a = NSAlert()
                        a.messageText = "双语翻译未完成"
                        a.informativeText = "\(err)\n\n已加载原始字幕，双语字幕未生成。"
                        a.alertStyle = .informational
                        a.runModal()
                    }
                }
            }
        }
    }

    // MARK: - Apple Translation (macOS 15+)

    private struct SRTBlock {
        let index: String
        let timing: String
        let text: String   // 原始文本，可能多行
    }

    private func parseSRTBlocks(_ content: String) -> [SRTBlock] {
        var blocks: [SRTBlock] = []
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for chunk in normalized.components(separatedBy: "\n\n") {
            let lines = chunk.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard lines.count >= 2,
                  let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let idx  = ti > 0 ? lines[0] : String(blocks.count + 1)
            let text = lines[(ti + 1)...].joined(separator: "\n")
            blocks.append(SRTBlock(index: idx, timing: lines[ti], text: text))
        }
        return blocks
    }

    /// 返回 (译文SRT路径, 错误说明)；成功时错误为 nil
    @available(macOS 26, *)
    private func translateSRT(at url: URL, sourceLang: String, targetLang: String) async -> (URL?, String?) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return (nil, "无法读取 SRT 文件")
        }
        let blocks = parseSRTBlocks(content)
        guard !blocks.isEmpty else { return (nil, "SRT 解析结果为空") }

        // 每个 block 文本合并为单行送翻译（避免多行混淆）
        let texts = blocks.map { $0.text.replacingOccurrences(of: "\n", with: " ") }

        let srcLang   = Locale.Language(identifier: sourceLang)
        let dstLangId = targetLang == "zh" ? "zh-Hans" : targetLang
        let dstLang   = Locale.Language(identifier: dstLangId)

        // macOS 26 直接初始化 TranslationSession
        let session = TranslationSession(installedSource: srcLang, target: dstLang)

        do {
            let requests  = texts.map { TranslationSession.Request(sourceText: $0) }
            let responses = try await session.translations(from: requests)

            var srt = ""
            for (i, block) in blocks.enumerated() {
                let translation = i < responses.count
                    ? responses[i].targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                srt += "\(block.index)\n\(block.timing)\n\(block.text)"
                if !translation.isEmpty { srt += "\n\(translation)" }
                srt += "\n\n"
            }

            let outURL = url.deletingPathExtension()
                .appendingPathExtension(targetLang + ".srt")
            try srt.write(to: outURL, atomically: true, encoding: .utf8)
            return (outURL, nil)
        } catch {
            return (nil, "翻译框架错误：\(error.localizedDescription)\n\n请确认已在「系统设置 → 通用 → 语言与地区」下载所需语言包。")
        }
    }

    /// Returns the URL to play: renamed .mp4 if user agreed, nil to play original.
    // MARK: - Convert to MKV

    /// 当前有任意字幕 tab（且有数据）时显示转换按钮
    var canConvertToMKV: Bool {
        availableTracks.contains { track in
            if track.id <= -100 { return externalTrackURLs[track.id] != nil }
            return subtitleCache[.single(track)] != nil
        }
    }

    func convertToMKV() {
        guard let videoURL,
              let ffmpeg = SubtitleExtractor.ffmpegPath else { return }

        // 辅助：把 TimeInterval 格式化为 SRT 时间戳 HH:MM:SS,mmm
        func formatSRTTime(_ t: TimeInterval) -> String {
            let totalMs = Int(max(0, t) * 1000)
            let ms = totalMs % 1000
            let s  = (totalMs / 1000) % 60
            let m  = (totalMs / 60000) % 60
            let h  = totalMs / 3600000
            return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
        }

        // ── 按来源把当前所有 tab 分为三类 ──────────────────────────────
        //
        //  1. embeddedSubTracks (id >= 0)      视频内部字幕流，ffmpeg 可用 0:s:N 直接映射
        //  2. companionSubTracks (id < 0 && id > -100)  同目录伴随文件（video.srt 等）
        //  3. externalSubTracks  (id <= -100)  用户手动加载的外挂文件
        //
        // 1 类无需额外输入，直接在 buildArgs 用 -map 0:s:{index} 指定；
        // 2、3 类收集文件 URL，作为 ffmpeg 的额外输入流。

        let embeddedSubTracks = availableTracks.filter { $0.id >= 0 }

        var fileSubURLs: [URL] = []        // 文件型字幕（按 tab 顺序）
        let videoDir = videoURL.deletingLastPathComponent()
        for track in availableTracks {
            if track.id < 0 && track.id > -100 {
                // 伴随文件：track.title 即文件名
                if let title = track.title {
                    let url = videoDir.appendingPathComponent(title)
                    if FileManager.default.fileExists(atPath: url.path) {
                        fileSubURLs.append(url)
                    }
                }
            } else if track.id <= -100 {
                if let url = externalTrackURLs[track.id] { fileSubURLs.append(url) }
            }
        }

        guard !embeddedSubTracks.isEmpty || !fileSubURLs.isEmpty else { return }
        let subURLs = fileSubURLs          // 传入 Task 供 prepareSubtitle 处理
        let builtInTempFiles: [URL] = []   // 无需手动创建临时文件，嵌入流直接用 -map

        // 确认弹窗
        let confirm = NSAlert()
        confirm.messageText = "转换为内嵌字幕 MKV"
        confirm.informativeText = "将当前视频和外挂字幕合并为一个 MKV 文件，字幕将内嵌其中，播放更流畅精准。"
        confirm.alertStyle = .informational
        confirm.addButton(withTitle: "是，开始转换")
        confirm.addButton(withTitle: "否，取消")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        // 输出路径：同目录下 cleanStem.embedded.mkv
        // 先去掉已有的 .embedded 后缀链，防止重复打包时叠加（03.embedded.embedded...）
        let outVideoDir = videoURL.deletingLastPathComponent()
        var cleanStem = videoURL.deletingPathExtension().lastPathComponent
        while cleanStem.lowercased().hasSuffix(".embedded") {
            cleanStem = String(cleanStem.dropLast(".embedded".count))
        }
        var outURL = outVideoDir.appendingPathComponent(cleanStem + ".embedded.mkv")
        // 如果清理后仍与输入路径相同（极罕见），加 _new 避免 ffmpeg 读写同一文件
        if outURL.path == videoURL.path {
            outURL = outVideoDir.appendingPathComponent(cleanStem + ".embedded_new.mkv")
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

                // 精确映射：只保留视音频，字幕流由下面逐一控制
                args += ["-map", "0:V"]   // 所有视频流
                args += ["-map", "0:a?"]  // 所有音频流（? = 无音频时不报错）

                // 仍在 tab 里的内嵌字幕流：用字幕相对索引映射
                for track in embeddedSubTracks {
                    args += ["-map", "0:s:\(track.index)"]
                }
                // 文件型字幕（companion + 外挂）：各自作为独立输入流
                for i in 1...max(1, preparedSubPaths.count) where i <= preparedSubPaths.count {
                    args += ["-map", "\(i):0"]
                }
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
            builtInTempFiles.forEach { try? FileManager.default.removeItem(at: $0) }

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
