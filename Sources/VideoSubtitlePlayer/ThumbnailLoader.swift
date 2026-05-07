import AVFoundation
import AppKit

// MARK: - 磁盘 + 内存双层缓存

final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memory = NSCache<NSString, NSImage>()
    private let dir: URL

    private init() {
        memory.countLimit = 60
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        dir = base.appendingPathComponent("SubMelon/thumbnails")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // 稳定哈希（String.hashValue 跨进程不稳定）
    private func key(_ path: String) -> String {
        var h: UInt64 = 5381
        for b in path.utf8 { h = h &* 31 &+ UInt64(b) }
        return String(format: "%016llx", h)
    }
    private func diskURL(_ path: String) -> URL { dir.appendingPathComponent("\(key(path)).jpg") }

    func get(_ path: String) -> NSImage? {
        if let img = memory.object(forKey: path as NSString) { return img }
        guard let data = try? Data(contentsOf: diskURL(path)),
              let img = NSImage(data: data) else { return nil }
        memory.setObject(img, forKey: path as NSString)
        return img
    }

    func set(_ image: NSImage, for path: String) {
        memory.setObject(image, forKey: path as NSString)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        else { return }
        try? data.write(to: diskURL(path))
    }

    func remove(for path: String) {
        memory.removeObject(forKey: path as NSString)
        try? FileManager.default.removeItem(at: diskURL(path))
    }

    func removeAll(for paths: [String]) {
        paths.forEach { remove(for: $0) }
    }

    func clearAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

// MARK: - 生成入口

func loadVideoThumbnail(path: String) async -> NSImage? {
    // 内存 / 磁盘命中直接返回
    if let cached = ThumbnailCache.shared.get(path) { return cached }
    guard FileManager.default.fileExists(atPath: path) else { return nil }

    let image = await Task.detached(priority: .background) {
        await generateThumbnail(path: path)
    }.value

    if let image { ThumbnailCache.shared.set(image, for: path) }
    return image
}

// MARK: - 生成（在 detached Task 里调用）

private func generateThumbnail(path: String) async -> NSImage? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    var duration = (try? await asset.load(.duration))?.seconds ?? 0

    // AVFoundation 无法读取 MKV 等容器的时长，用 ffmpeg 补充
    if duration <= 0 || !duration.isFinite {
        duration = ffmpegDuration(path: path)
    }

    let seekSecs = (duration > 0 && duration.isFinite) ? duration / 2 : 30.0

    if let img = avfThumbnail(asset: asset, at: seekSecs) { return img }
    return ffmpegThumbnail(path: path, at: seekSecs)
}

private func ffmpegDuration(path: String) -> Double {
    guard let ffmpeg = SubtitleExtractor.ffmpegPath else { return 0 }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: ffmpeg)
    proc.arguments = ["-i", path]
    proc.standardOutput = FileHandle.nullDevice
    let pipe = Pipe()
    proc.standardError = pipe
    guard (try? proc.run()) != nil else { return 0 }
    proc.waitUntilExit()
    let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    // 解析 "Duration: HH:MM:SS.ss"
    guard let match = try? NSRegularExpression(pattern: #"Duration:\s*(\d+):(\d+):([\d.]+)"#)
            .firstMatch(in: stderr, range: NSRange(stderr.startIndex..., in: stderr)),
          let r1 = Range(match.range(at: 1), in: stderr),
          let r2 = Range(match.range(at: 2), in: stderr),
          let r3 = Range(match.range(at: 3), in: stderr)
    else { return 0 }
    let h = Double(stderr[r1]) ?? 0
    let m = Double(stderr[r2]) ?? 0
    let s = Double(stderr[r3]) ?? 0
    return h * 3600 + m * 60 + s
}

private func avfThumbnail(asset: AVURLAsset, at secs: Double) -> NSImage? {
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 240, height: 135)
    gen.requestedTimeToleranceBefore = CMTime(seconds: 5, preferredTimescale: 600)
    gen.requestedTimeToleranceAfter  = CMTime(seconds: 5, preferredTimescale: 600)
    guard let cgImg = try? gen.copyCGImage(at: CMTime(seconds: secs, preferredTimescale: 600), actualTime: nil)
    else { return nil }
    return NSImage(cgImage: cgImg, size: .zero)
}

private func ffmpegThumbnail(path: String, at secs: Double) -> NSImage? {
    guard let ffmpeg = SubtitleExtractor.ffmpegPath else { return nil }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vsp_\(UUID().uuidString).jpg")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: ffmpeg)
    proc.arguments = [
        "-y", "-ss", String(format: "%.3f", secs), "-i", path,
        "-frames:v", "1",
        "-update", "1",
        "-vf", "scale=240:-2",
        "-q:v", "5",
        tmp.path
    ]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError  = FileHandle.nullDevice
    guard (try? proc.run()) != nil else { return nil }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    return (try? Data(contentsOf: tmp)).flatMap { NSImage(data: $0) }
}
