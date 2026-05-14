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
    @Published var volume: Double = 50 {
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

        // 英文加载完后立即预缓存双语，无需等待
        if tracksSnapshot.count >= 2 {
            Task {
                let biMode = bilingualMode(from: tracksSnapshot)
                guard biMode != mode else { return }
                let alreadyCached = await MainActor.run { self.subtitleCache[biMode] != nil }
                guard !alreadyCached else { return }
                if case .bilingual(let p, let s) = biMode {
                    let subs = await SubtitleExtractor.extractBilingual(from: url, primary: p, secondary: s)
                    await MainActor.run { self.subtitleCache[biMode] = subs }
                }
            }
        }

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
    private func syncCurrentSubtitle(at time: TimeInterval) {
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
        // 自然播放时，字幕在满足 startTime <= time 的第一帧出现；
        // 跳转时 seekExact(startTime) 会落在包含 startTime 的帧的 PTS（< startTime），
        // 导致匹配失败。直接 seek 到 startTime + 一帧（1/24s ≈ 42ms），
        // MPV 精确落在第一帧 PTS ≥ startTime，与自然播放行为完全一致。
        // 无状态机、无回调竞争。
        let seekTime = subtitle.startTime + 1.0 / 24.0
        currentTime = subtitle.startTime
        currentSubtitleIndex = subtitle.id
        sidebarHighlightIndex = subtitle.id
        if let mpv = mpvController {
            mpv.seekExact(to: seekTime)
            if !isPlaying { mpv.setPlaying(true); isPlaying = true }
        } else {
            let t = CMTime(seconds: seekTime, preferredTimescale: 600)
            player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            if player.timeControlStatus != .playing { player.play(); isPlaying = true }
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
            // 字幕间隙：sidebarHighlightIndex 指向刚结束的那条，上一条是它的前一条
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
            // 正在某条字幕上：跳到下一条
            let next = currentSubtitleIndex + 1
            if next < subtitles.count { jumpToSubtitle(subtitles[next]) }
        } else {
            // 字幕间隙：跳到当前时间之后开始的第一条字幕
            if let target = subtitles.firstIndex(where: { $0.startTime > now }) {
                jumpToSubtitle(subtitles[target])
            }
        }
    }

    func jumpToFirstSubtitle() {
        guard let first = subtitles.first else { return }
        jumpToSubtitle(first)
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

    /// Raw order derived from availableTracks (builtin first, then external).
    private func buildRawModes() -> [SubtitleMode] {
        let tracks = availableTracks
        guard !tracks.isEmpty else { return [] }
        var modes: [SubtitleMode] = []
        let builtin = tracks.filter { $0.id > -100 }
        if let primary = builtin.first {
            modes.append(.single(primary))
            if builtin.count >= 2 { modes.append(bilingualMode(from: builtin)) }
        }
        for track in tracks where track.id <= -100 { modes.append(.single(track)) }
        return modes
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
