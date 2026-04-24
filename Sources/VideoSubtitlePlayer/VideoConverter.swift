import Foundation

enum VideoConverter {

    /// Remux to a temp MP4. Video is copied; audio is transcoded to AAC for AVFoundation compatibility.
    /// Returns the temp URL on success; caller must delete when done.
    static func remux(url: URL, ffmpegPath: String,
                      onProgress: @escaping @Sendable (Double) -> Void) async -> URL? {

        let duration = await getDuration(url: url, ffmpegPath: ffmpegPath)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-i", url.path,
            "-map", "0:v:0",
            "-map", "0:a?",
            "-c:v", "copy",
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "faststart",
            "-progress", "pipe:2",   // structured machine-readable progress → stderr
            "-loglevel", "quiet",    // suppress everything else
            "-y", output.path
        ]
        proc.standardInput = FileHandle.nullDevice
        if let devNull = FileHandle(forWritingAtPath: "/dev/null") {
            proc.standardOutput = devNull
        }

        let errPipe = Pipe()
        proc.standardError = errPipe

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            guard let text = String(data: handle.availableData, encoding: .utf8) else { return }
            // -progress outputs lines like: out_time=HH:MM:SS.ffffff
            if let t = parseProgressTime(text), duration > 0 {
                onProgress(min(t / duration, 0.99))
            }
        }

        return await withCheckedContinuation { continuation in
            let timeout = DispatchWorkItem {
                if proc.isRunning { proc.terminate() }
                try? FileManager.default.removeItem(at: output)
                continuation.resume(returning: nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: timeout)

            proc.terminationHandler = { p in
                timeout.cancel()
                errPipe.fileHandleForReading.readabilityHandler = nil
                if p.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: output.path) {
                    onProgress(1.0)
                    continuation.resume(returning: output)
                } else {
                    try? FileManager.default.removeItem(at: output)
                    continuation.resume(returning: nil)
                }
            }
            do { try proc.run() } catch {
                timeout.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Duration via ffmpeg -i (no ffprobe needed)

    static func getDuration(url: URL, ffmpegPath: String) async -> TimeInterval {
        return await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpegPath)
            proc.arguments = ["-i", url.path]   // ffmpeg -i always exits 1, but prints file info
            if let devNull = FileHandle(forWritingAtPath: "/dev/null") {
                proc.standardOutput = devNull
            }
            let errPipe = Pipe()
            proc.standardError = errPipe

            var collected = Data()
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                if !chunk.isEmpty { collected.append(chunk) }
            }
            proc.terminationHandler = { _ in
                errPipe.fileHandleForReading.readabilityHandler = nil
                collected.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                let text = String(data: collected, encoding: .utf8) ?? ""
                continuation.resume(returning: parseDuration(from: text))
            }
            do { try proc.run() } catch { continuation.resume(returning: 0) }
        }
    }

    // MARK: - Parsers

    // Parses "Duration: HH:MM:SS.ms" from ffmpeg -i output
    private static func parseDuration(from text: String) -> TimeInterval {
        guard let r = text.range(of: #"Duration: (\d+):(\d+):(\d+\.?\d*)"#, options: .regularExpression) else { return 0 }
        let parts = String(text[r]).dropFirst(10).split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return 0 }
        return h * 3600 + m * 60 + s
    }

    // Parses "out_time=HH:MM:SS.ffffff" from -progress output
    private static func parseProgressTime(_ text: String) -> TimeInterval? {
        guard let r = text.range(of: #"out_time=(\d+):(\d+):(\d+\.?\d*)"#, options: .regularExpression) else { return nil }
        let parts = String(text[r]).dropFirst(9).split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}
