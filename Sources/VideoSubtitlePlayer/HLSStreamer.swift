import Foundation

/// Streams any video format to AVPlayer by writing a fragmented MP4 file
/// that AVFoundation can read while FFmpeg is still encoding it.
/// Video is copied (no re-encode); only audio is transcoded to AAC.
final class FragStreamer {
    private var process: Process?
    private(set) var outputURL: URL?

    func start(url: URL, ffmpegPath: String) async -> URL? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-i", url.path,
            "-c:v", "copy",                  // copy video — instant, no re-encode
            "-c:a", "aac", "-b:a", "192k",   // audio → AAC for AVFoundation
            "-f", "mp4",
            // frag_keyframe: write one fragment per keyframe (streamable)
            // empty_moov:    write format header at file start so AVPlayer can open immediately
            // default_base_moof: self-contained fragments for random access
            "-movflags", "frag_keyframe+empty_moov+default_base_moof",
            "-loglevel", "quiet",
            "-y", output.path
        ]
        proc.standardInput = FileHandle.nullDevice
        if let devNull = FileHandle(forWritingAtPath: "/dev/null") {
            proc.standardOutput = devNull
            proc.standardError = devNull
        }

        do { try proc.run() } catch { return nil }
        process = proc
        outputURL = output

        // Wait for FFmpeg to write the moov header + first fragment
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > 50_000 { return output }  // enough data for AVPlayer to initialize
        }

        return nil
    }

    func cleanup() {
        process?.terminate()
        process = nil
        if let f = outputURL { try? FileManager.default.removeItem(at: f) }
        outputURL = nil
    }

    deinit { cleanup() }
}
