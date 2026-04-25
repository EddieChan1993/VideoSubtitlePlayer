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

    static let ffmpegPath: String? =
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.fileExists(atPath: $0) }

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
        var result: [Subtitle] = []
        var used = Set<Int>()
        for sub in primary {
            let matches = secondary.enumerated().filter { !used.contains($0.offset) &&
                max(sub.startTime, $0.element.startTime) < min(sub.endTime, $0.element.endTime) }
            matches.forEach { used.insert($0.offset) }

            let text: String
            if matches.isEmpty {
                text = sub.text
            } else {
                // Deduplicate by line: only append secondary lines not already in primary.
                // Handles the common case where one track already stores "English\nChinese"
                // per entry — merging naively would produce "English\nChinese\nEnglish".
                let primaryLines = Set(
                    sub.cleanText
                        .components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                )
                let newLines = matches.flatMap { m in
                    m.element.cleanText
                        .components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty && !primaryLines.contains($0) }
                }
                text = newLines.isEmpty
                    ? sub.cleanText
                    : sub.cleanText + "\n" + newLines.joined(separator: "\n")
            }
            result.append(Subtitle(id: result.count, startTime: sub.startTime, endTime: sub.endTime, text: text))
        }
        for (j, sec) in secondary.enumerated() where !used.contains(j) {
            result.append(Subtitle(id: result.count, startTime: sec.startTime, endTime: sec.endTime, text: sec.text))
        }
        let sorted = result.sorted { $0.startTime < $1.startTime }
        return sorted.enumerated().map { Subtitle(id: $0, startTime: $1.startTime, endTime: $1.endTime, text: $1.text) }
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
