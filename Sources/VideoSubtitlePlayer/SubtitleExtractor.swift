import Foundation
@preconcurrency import AVFoundation

enum SubtitleExtractor {

    // MARK: - Public API

    /// Fast path: extract tracks 0 & 1 directly, then refine labels in background.
    /// Returns (subtitles for immediate display, all found tracks).
    static func extractImmediate(from url: URL) async -> ([Subtitle], [SubtitleTrack]) {
        // 1. Companion files
        let companions = findCompanionTracks(for: url)
        if !companions.isEmpty {
            let subs = extractCompanion(for: url, track: companions[0])
            return (subs, companions)
        }

        // 2. Try embedded tracks 0 & 1 in parallel (no need to list first)
        async let s0 = extractWithFFmpeg(from: url, subtitleIndex: 0)
        async let s1 = extractWithFFmpeg(from: url, subtitleIndex: 1)
        let (r0, r1) = await (s0, s1)

        var tracks: [SubtitleTrack] = []
        if let _ = r0 { tracks.append(SubtitleTrack(id: 0, index: 0, language: nil, title: nil)) }
        if let _ = r1 { tracks.append(SubtitleTrack(id: 1, index: 1, language: nil, title: nil)) }

        // Return first non-empty result right away
        return (r0 ?? r1 ?? [], tracks)
    }

    /// Background track listing with language labels (updates the UI picker).
    /// Parses ffmpeg -i stderr — best-effort, doesn't block subtitle display.
    static func listTracksWithLabels(from url: URL) async -> [SubtitleTrack] {
        guard let ffmpeg = ffmpegPath else { return [] }

        return await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = ["-i", url.path]
            // ffmpeg always exits with 1 when no output is given — we only need stderr
            proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            let errPipe = Pipe()
            proc.standardError = errPipe

            let collected = DataBox()
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                if !chunk.isEmpty { collected.append(chunk) }
            }

            proc.terminationHandler = { _ in
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Drain anything left in the buffer
                collected.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                let text = String(data: collected.data, encoding: .utf8) ?? ""
                continuation.resume(returning: parseFFmpegStreams(text))
            }
            do { try proc.run() } catch { continuation.resume(returning: []) }
        }
    }

    /// Extract a single track by its subtitle-stream index.
    static func extract(from url: URL, track: SubtitleTrack) async -> [Subtitle] {
        if track.id < 0 { return extractCompanion(for: url, track: track) }
        return await extractWithFFmpeg(from: url, subtitleIndex: track.index) ?? []
    }

    /// Extract two tracks in parallel and merge.
    static func extractBilingual(from url: URL,
                                  primary: SubtitleTrack,
                                  secondary: SubtitleTrack) async -> [Subtitle] {
        async let a = extract(from: url, track: primary)
        async let b = extract(from: url, track: secondary)
        return mergeBilingual(await a, await b)
    }

    // MARK: - Companion files

    static func findCompanionTracks(for url: URL) -> [SubtitleTrack] {
        let base = url.deletingPathExtension()
        return ["srt","vtt","webvtt","ass","ssa"].enumerated().compactMap { i, ext in
            let f = base.appendingPathExtension(ext)
            guard FileManager.default.fileExists(atPath: f.path) else { return nil }
            return SubtitleTrack(id: -1 - i, index: i,
                                 language: langFromFilename(f), title: f.lastPathComponent)
        }
    }

    static func extractCompanion(for url: URL, track: SubtitleTrack) -> [Subtitle] {
        let base = url.deletingPathExtension()
        for ext in ["srt","vtt","webvtt","ass","ssa"] {
            let f = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: f.path),
               track.title == f.lastPathComponent { return SubtitleParser.parse(url: f) }
        }
        return []
    }

    // MARK: - FFmpeg

    static let ffmpegPath: String? = {
        let fm = FileManager.default
        // 优先使用 Bundle 内打包的 ffmpeg（发布包无需 Homebrew）
        if let bundled = Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("ffmpeg").path,
           fm.fileExists(atPath: bundled) { return bundled }
        return ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { fm.fileExists(atPath: $0) }
    }()

    private static func extractWithFFmpeg(from url: URL, subtitleIndex: Int) async -> [Subtitle]? {
        guard let ffmpeg = ffmpegPath else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".srt")
        let devNull = FileHandle(forWritingAtPath: "/dev/null")

        return await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = [
                "-nostdin", "-loglevel", "error",
                "-i", url.path,
                "-map", "0:s:\(subtitleIndex)",
                "-c:s", "copy",
                "-y", tmp.path
            ]
            proc.standardOutput = devNull
            proc.standardError = devNull

            let timeout = DispatchWorkItem {
                if proc.isRunning { proc.terminate() }
                try? FileManager.default.removeItem(at: tmp)
                continuation.resume(returning: nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)

            proc.terminationHandler = { p in
                timeout.cancel()
                guard p.terminationStatus == 0,
                      FileManager.default.fileExists(atPath: tmp.path) else {
                    try? FileManager.default.removeItem(at: tmp)
                    continuation.resume(returning: nil)
                    return
                }
                let subs = SubtitleParser.parse(url: tmp)
                try? FileManager.default.removeItem(at: tmp)
                continuation.resume(returning: subs.isEmpty ? nil : subs)
            }
            do { try proc.run() } catch {
                timeout.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - AVFoundation fallback

    private static func extractWithAVFoundation(from url: URL) async -> [Subtitle]? {
        let asset = AVAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .text).first else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                    reader.add(output)
                    guard reader.startReading() else { continuation.resume(returning: nil); return }
                    var subs: [Subtitle] = []
                    while let buf = output.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(buf).seconds
                        let dur = CMSampleBufferGetDuration(buf).seconds
                        guard let db = CMSampleBufferGetDataBuffer(buf) else { continue }
                        var len = 0; var ptr: UnsafeMutablePointer<Int8>?
                        CMBlockBufferGetDataPointer(db, atOffset: 0, lengthAtOffsetOut: nil,
                                                   totalLengthOut: &len, dataPointerOut: &ptr)
                        guard let ptr, len > 2 else { continue }
                        let data = Data(bytes: ptr + 2, count: len - 2)
                        guard let text = String(data: data, encoding: .utf8),
                              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        subs.append(Subtitle(id: subs.count, startTime: pts, endTime: pts + dur, text: text))
                    }
                    continuation.resume(returning: subs.isEmpty ? nil : subs)
                } catch { continuation.resume(returning: nil) }
            }
        }
    }

    // MARK: - Bilingual merge

    static func mergeBilingual(_ primary: [Subtitle], _ secondary: [Subtitle]) -> [Subtitle] {
        // If primary already has multi-line entries mixing CJK and Latin, it's already bilingual
        let alreadyBilingual = primary.prefix(5).filter { sub -> Bool in
            let lines = sub.cleanText.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard lines.count >= 2 else { return false }
            let hasCJK = lines.contains { line in line.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF } }
            let hasLatin = lines.contains { line in line.unicodeScalars.filter { $0.value >= 65 && $0.value <= 90 || $0.value >= 97 && $0.value <= 122 }.count >= 4 }
            return hasCJK && hasLatin
        }.count >= 2
        if alreadyBilingual { return primary }

        var result: [Subtitle] = []
        var used = Set<Int>()
        for sub in primary {
            // 只取重叠时长最大的那一条次轨，避免一条主轨吞并多条次轨产生超长合并项
            let bestMatch = secondary.enumerated()
                .filter { !used.contains($0.offset) &&
                    max(sub.startTime, $0.element.startTime) < min(sub.endTime, $0.element.endTime) }
                .max { a, b in
                    let oa = min(sub.endTime, a.element.endTime) - max(sub.startTime, a.element.startTime)
                    let ob = min(sub.endTime, b.element.endTime) - max(sub.startTime, b.element.startTime)
                    return oa < ob
                }
            if let m = bestMatch { used.insert(m.offset) }

            let text: String
            if let m = bestMatch {
                let primaryLines = Set(
                    sub.cleanText
                        .components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                )
                let newLines = m.element.cleanText
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !primaryLines.contains($0) }
                text = newLines.isEmpty ? sub.cleanText : sub.cleanText + "\n" + newLines.joined(separator: "\n")
            } else {
                text = sub.text
            }
            result.append(Subtitle(id: result.count, startTime: sub.startTime, endTime: sub.endTime, text: text))
        }
        let sorted = result.sorted { $0.startTime < $1.startTime }
        return sorted.enumerated().map { Subtitle(id: $0, startTime: $1.startTime, endTime: $1.endTime, text: $1.text) }
    }

    // MARK: - Language detection from content

    /// Detects display label from subtitle content (used when ffmpeg reports no language tag).
    /// Returns "英文", "中文", or nil when undetermined.
    static func languageLabel(from subtitles: [Subtitle]) -> String? {
        let sample = Array(subtitles.prefix(15))
        guard !sample.isEmpty else { return nil }

        func hasCJK(_ s: String) -> Bool { s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF } }
        func hasLat(_ s: String) -> Bool { s.unicodeScalars.contains { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) } }

        // If 2+ individual entries each contain both scripts, the track is bilingual
        let mixed = sample.filter { let t = $0.cleanText; return hasCJK(t) && hasLat(t) }
        if mixed.count >= 2 { return "双语" }

        let allText = sample.map { $0.cleanText }.joined()
        guard !allText.isEmpty else { return nil }
        let cjk = allText.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let lat = allText.unicodeScalars.filter { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }.count
        guard cjk + lat > 0 else { return nil }
        return cjk > lat ? "中文" : "英文"
    }

    // MARK: - Parse ffmpeg -i output

    /// Stream #0:2(chi): Subtitle: ass  →  SubtitleTrack(index:0, language:"chi")
    private static func parseFFmpegStreams(_ text: String) -> [SubtitleTrack] {
        var tracks: [SubtitleTrack] = []
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            guard line.contains(": Subtitle:") else { continue }
            // Match Stream #X:Y or Stream #X:Y(lang)
            let pattern = #"Stream #\d+:(\d+)(?:\(([a-z]+)\))?"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
                tracks.append(SubtitleTrack(id: tracks.count, index: tracks.count, language: nil, title: nil))
                continue
            }
            func group(_ i: Int) -> String? {
                guard let r = Range(m.range(at: i), in: line), !line[r].isEmpty else { return nil }
                return String(line[r])
            }
            let globalIdx = Int(group(1) ?? "") ?? tracks.count
            tracks.append(SubtitleTrack(id: globalIdx, index: tracks.count,
                                        language: group(2), title: nil))
        }
        return tracks
    }

    private static func langFromFilename(_ url: URL) -> String? {
        let n = url.deletingPathExtension().lastPathComponent.lowercased()
        if n.hasSuffix(".zh") || n.hasSuffix(".chs") || n.hasSuffix(".chi") { return "zh" }
        if n.hasSuffix(".en") || n.hasSuffix(".eng") { return "en" }
        return nil
    }
}
