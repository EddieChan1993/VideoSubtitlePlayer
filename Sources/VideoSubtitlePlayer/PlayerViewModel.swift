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
    @Published var currentTime: Double = 0
    @Published var videoDuration: Double = 0
    @Published var volume: Double = 50 {
        didSet {
            if useMPV { mpvController?.setVolume(volume) }
            else { player.volume = Float(volume / 100.0) }
        }
    }
    private(set) var mpvController: MPVController?

    private(set) var videoURL: URL?
    private var fragStreamer: FragStreamer?
    private var tempVideoURL: URL?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?

    private var subtitleCache: [SubtitleMode: [Subtitle]] = [:]

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
        subtitles = []
        availableTracks = []
        selectedMode = nil
        currentSubtitleIndex = -1
        sidebarHighlightIndex = -1
        videoError = nil
        isPlaying = false
        isPreparing = false
        isLoadingSubtitles = true
        loadingStatus = "提取字幕中…"
        currentTime = 0
        videoDuration = 0
        subtitleCache = [:]

        Task { await extractSubtitles(from: url) }
        playDirectly(url: url)
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

        await MainActor.run {
            self.availableTracks = immediateTracks
            if !immediateSubs.isEmpty {
                if let first = immediateTracks.first {
                    let mode = SubtitleMode.single(first)
                    self.selectedMode = mode
                    self.subtitleCache[mode] = immediateSubs
                }
                self.subtitles = immediateSubs
                self.currentSubtitleIndex = -1
                self.isLoadingSubtitles = false
                self.loadingStatus = "已加载 \(immediateSubs.count) 条字幕"
            }
        }

        let labeledTracks = await SubtitleExtractor.listTracksWithLabels(from: url)
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
            let changed = self.subtitles.isEmpty || self.selectedMode != mode
            self.selectedMode = mode
            if changed {
                self.isLoadingSubtitles = true
                self.loadingStatus = "提取字幕中…"
            }
            return changed
        }

        if needsLoad { await loadSubtitles(for: mode, url: url) }

        Task { await preCacheOtherTracks(tracksSnapshot, url: url, skipMode: mode) }
    }

    private func preCacheOtherTracks(_ tracks: [SubtitleTrack], url: URL, skipMode: SubtitleMode) async {
        for track in tracks {
            let mode = SubtitleMode.single(track)
            guard mode != skipMode, subtitleCache[mode] == nil else { continue }
            subtitleCache[mode] = await SubtitleExtractor.extract(from: url, track: track)
        }
        let cn = tracks.filter { $0.isChinese }
        let en = tracks.filter { $0.isEnglish }
        for c in cn {
            for e in en {
                let mode = SubtitleMode.bilingual(c, e)
                guard mode != skipMode, subtitleCache[mode] == nil else { continue }
                subtitleCache[mode] = await SubtitleExtractor.extractBilingual(from: url, primary: c, secondary: e)
            }
        }
    }

    func selectMode(_ mode: SubtitleMode) {
        guard let url = videoURL else { return }
        selectedMode = mode

        if let cached = subtitleCache[mode] {
            subtitles = cached
            currentSubtitleIndex = -1
            isLoadingSubtitles = false
            loadingStatus = "已加载 \(cached.count) 条字幕"
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
            subs = track.id < 0
                ? SubtitleExtractor.extractCompanion(for: url, track: track)
                : await SubtitleExtractor.extract(from: url, track: track)
        case .bilingual(let primary, let secondary):
            if primary.id < 0 || secondary.id < 0 {
                let a = SubtitleExtractor.extractCompanion(for: url, track: primary)
                let b = SubtitleExtractor.extractCompanion(for: url, track: secondary)
                subs = SubtitleExtractor.mergeBilingual(a, b)
            } else {
                subs = await SubtitleExtractor.extractBilingual(from: url, primary: primary, secondary: secondary)
            }
        }
        subtitleCache[mode] = subs
        await MainActor.run {
            guard self.selectedMode == mode else { return }
            self.subtitles = subs
            self.currentSubtitleIndex = -1
            self.isLoadingSubtitles = false
            self.loadingStatus = subs.isEmpty ? "无字幕内容" : "已加载 \(subs.count) 条字幕"
        }
    }

    // MARK: - Time sync

    /// 记录最新播放时间，供导航函数在字幕间隙时使用
    private var currentPlaybackTime: TimeInterval = 0

    private func syncCurrentSubtitle(at time: TimeInterval) {
        currentPlaybackTime = time
        currentTime = time
        if !useMPV, let dur = player.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
            videoDuration = dur
        }
        let idx = subtitles.firstIndex { $0.startTime <= time && $0.endTime > time } ?? -1
        if idx != currentSubtitleIndex { currentSubtitleIndex = idx }
        // sidebarHighlightIndex only advances forward — never reverts to -1 between subtitles.
        // This keeps the sidebar showing the last seen entry highlighted.
        if idx >= 0 { sidebarHighlightIndex = idx }
    }

    /// 取当前播放位置（AVPlayer 或 MPV 均适用）
    private var now: TimeInterval {
        useMPV ? currentPlaybackTime : player.currentTime().seconds
    }

    // MARK: - Navigation

    func seek(to time: Double) {
        if let mpv = mpvController {
            mpv.seekExact(to: time)
        } else {
            let t = CMTime(seconds: time, preferredTimescale: 600)
            player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func jumpToSubtitle(_ subtitle: Subtitle) {
        currentTime = subtitle.startTime
        if let mpv = mpvController {
            mpv.seekExact(to: subtitle.startTime)
            if !isPlaying {
                mpv.setPlaying(true)
                isPlaying = true
            }
        } else {
            let t = CMTime(seconds: subtitle.startTime, preferredTimescale: 600)
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
            // 字幕间隙：找当前时间之前结束的最后一条字幕
            target = subtitles.lastIndex { $0.endTime <= now } ?? 0
        }
        jumpToSubtitle(subtitles[target])
    }

    func restartCurrentSubtitle() {
        guard currentSubtitleIndex >= 0, currentSubtitleIndex < subtitles.count else { return }
        jumpToSubtitle(subtitles[currentSubtitleIndex])
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

    // MARK: - Track label

    /// Returns a display label for a track; falls back to content-based language detection
    /// when the file has no language tag (shows "Track N").
    func trackLabel(for track: SubtitleTrack) -> String {
        if track.isEnglish { return "英文" }
        if track.isChinese { return "中文" }
        if let lang = track.language, !lang.isEmpty { return lang.uppercased() }
        let cached = subtitleCache[.single(track)] ?? []
        return SubtitleExtractor.languageLabel(from: cached) ?? track.displayName
    }

    // MARK: - Playback control

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

    // MARK: - Cleanup

    private func cleanupTempFile() {
        if let tmp = tempVideoURL {
            try? FileManager.default.removeItem(at: tmp)
            tempVideoURL = nil
        }
    }
}
