import Foundation
import CoreFoundation

enum SubtitleParser {

    // GBK/GB2312 encoding used by many older Chinese subtitle files
    private static let gbkEncoding: String.Encoding = {
        let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632)) // kCFStringEncodingGBK_95
        return String.Encoding(rawValue: cf)
    }()

    static func parse(url: URL) -> [Subtitle] {
        guard let raw = (try? String(contentsOf: url, encoding: .utf8))
                     ?? (try? String(contentsOf: url, encoding: gbkEncoding))
                     ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return [] }
        switch url.pathExtension.lowercased() {
        case "srt":          return parseSRT(raw)
        case "vtt", "webvtt": return parseVTT(raw)
        case "ass", "ssa":   return parseASS(raw)
        default:
            let srt = parseSRT(raw)
            return srt.isEmpty ? parseVTT(raw) : srt
        }
    }

    // MARK: - SRT

    static func parseSRT(_ raw: String) -> [Subtitle] {
        let content = normalize(raw)
        var subtitles: [Subtitle] = []

        for block in content.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard lines.count >= 2,
                  let timingIdx = lines.firstIndex(where: { $0.contains("-->") }),
                  let timing = parseSRTTiming(lines[timingIdx]) else { continue }

            let text = lines[(timingIdx + 1)...].joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            subtitles.append(Subtitle(id: subtitles.count, startTime: timing.0, endTime: timing.1, text: text))
        }
        return deduplicateByStartTime(subtitles)
    }

    // 相同 startTime 保留最后一条（去掉字幕作者在片头写的重复水印行）
    private static func deduplicateByStartTime(_ subs: [Subtitle]) -> [Subtitle] {
        var seen: [TimeInterval: Int] = [:]       // startTime → index in result
        var result: [Subtitle] = []
        for sub in subs {
            if let existing = seen[sub.startTime] {
                result[existing] = Subtitle(id: existing, startTime: sub.startTime, endTime: sub.endTime, text: sub.text)
            } else {
                seen[sub.startTime] = result.count
                result.append(Subtitle(id: result.count, startTime: sub.startTime, endTime: sub.endTime, text: sub.text))
            }
        }
        return result
    }

    private static func parseSRTTiming(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let s = parseSRTTime(parts[0].trimmingCharacters(in: .whitespaces)),
              let e = parseSRTTime(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (s, e)
    }

    private static func parseSRTTime(_ str: String) -> TimeInterval? {
        // HH:MM:SS,mmm  or  HH:MM:SS.mmm
        let s = str.replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    // MARK: - VTT

    static func parseVTT(_ raw: String) -> [Subtitle] {
        var content = normalize(raw)
        // Drop WEBVTT header line
        if let nl = content.range(of: "\n") { content = String(content[nl.upperBound...]) }

        var subtitles: [Subtitle] = []
        for block in content.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timingIdx = lines.firstIndex(where: { $0.contains("-->") }),
                  let timing = parseVTTTiming(lines[timingIdx]) else { continue }

            let text = lines[(timingIdx + 1)...].joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            subtitles.append(Subtitle(id: subtitles.count, startTime: timing.0, endTime: timing.1, text: text))
        }
        return subtitles
    }

    private static func parseVTTTiming(_ line: String) -> (TimeInterval, TimeInterval)? {
        // Strip cue settings after the end time
        let core = line.components(separatedBy: " ").prefix(3).joined(separator: " ")
        let parts = core.components(separatedBy: "-->")
        guard parts.count == 2,
              let s = parseVTTTime(parts[0].trimmingCharacters(in: .whitespaces)),
              let e = parseVTTTime(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (s, e)
    }

    private static func parseVTTTime(_ str: String) -> TimeInterval? {
        let parts = str.split(separator: ":")
        switch parts.count {
        case 2:  // MM:SS.mmm
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60 + s
        case 3:  // HH:MM:SS.mmm
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        default: return nil
        }
    }

    // MARK: - ASS/SSA

    static func parseASS(_ raw: String) -> [Subtitle] {
        var subtitles: [Subtitle] = []
        var inEvents = false
        var format: [String] = []

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[Events]" { inEvents = true; continue }
            if trimmed.hasPrefix("[") && inEvents { break }
            guard inEvents else { continue }

            if trimmed.hasPrefix("Format:") {
                format = trimmed.dropFirst(7).components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if trimmed.hasPrefix("Dialogue:") {
                let data = trimmed.dropFirst(9).trimmingCharacters(in: .whitespaces)
                let fields = splitASS(data, count: format.count)
                let si = format.firstIndex(of: "Start") ?? 1
                let ei = format.firstIndex(of: "End") ?? 2
                let ti = format.firstIndex(of: "Text") ?? max(0, format.count - 1)
                guard si < fields.count, ei < fields.count, ti < fields.count,
                      let s = parseASSTime(fields[si]), let e = parseASSTime(fields[ei]) else { continue }
                let text = cleanASSText(fields[ti...].joined(separator: ","))
                guard !text.isEmpty else { continue }
                subtitles.append(Subtitle(id: subtitles.count, startTime: s, endTime: e, text: text))
            }
        }
        return subtitles.sorted { $0.startTime < $1.startTime }
    }

    private static func splitASS(_ str: String, count: Int) -> [String] {
        var parts = str.components(separatedBy: ",")
        if parts.count > count {
            let tail = parts[(count - 1)...].joined(separator: ",")
            parts = Array(parts.prefix(count - 1)) + [tail]
        }
        return parts
    }

    private static func parseASSTime(_ str: String) -> TimeInterval? {
        // H:MM:SS.cs
        let parts = str.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    private static func cleanASSText(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
           .replacingOccurrences(of: "\r", with: "\n")
           // Some SRT files use "space-only" lines as block separators; treat them as blank lines
           .replacingOccurrences(of: "(?m)^[ \t]+$", with: "", options: .regularExpression)
    }
}
