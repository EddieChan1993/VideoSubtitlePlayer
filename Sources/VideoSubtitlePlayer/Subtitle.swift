import Foundation

struct Subtitle: Identifiable, Equatable {
    let id: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String

    var cleanText: String {
        var s = text
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        // ASS line-break codes that ffmpeg may preserve literally in SRT output
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        // Collapse newlines inside [...] annotations (e.g. "[\n音乐]" → "[音乐]")
        var fixed = ""; var inBracket = false
        for ch in s {
            if ch == "[" { inBracket = true }
            else if ch == "]" { inBracket = false }
            if ch == "\n" && inBracket { continue }
            fixed.append(ch)
        }
        s = fixed
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉 Whisper 说话人标记（行首 >> 或 > ）
        s = s.replacingOccurrences(of: #"^>>?\s*"#, with: "", options: [.regularExpression, .anchored])
        s = s.replacingOccurrences(of: #"\n>>?\s*"#, with: "\n", options: .regularExpression)
        // 同行英中拆分："English. 中文。" → "English.\n中文。"
        s = s.components(separatedBy: "\n").map(Self.splitLatinCJK).joined(separator: "\n")
        return s
    }

    /// 在同一行内，从第一个 CJK 字符处插入换行，把英文前缀和中文后缀分开。
    /// 仅当前缀含 ≥3 个拉丁字母且后缀 ≥2 字时生效，避免误切纯中文或纯英文行。
    private static func splitLatinCJK(_ line: String) -> String {
        guard let splitIdx = line.firstIndex(where: { $0.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF } }),
              splitIdx > line.startIndex else { return line }
        let pre = String(line[..<splitIdx]).trimmingCharacters(in: .whitespaces)
        let suf = String(line[splitIdx...])
        let latinCount = pre.unicodeScalars.filter {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
        }.count
        guard latinCount >= 3, suf.count >= 2 else { return line }
        return pre + "\n" + suf
    }

    /// Splits cleanText into display lines (newline-separated).
    var bilingualLines: [String] {
        cleanText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var startTimeString: String { formatTime(startTime) }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Reference-type wrapper around Data so it can be safely shared across
/// readabilityHandler / terminationHandler closures without Swift concurrency errors.
final class DataBox: @unchecked Sendable {
    private(set) var data = Data()
    func append(_ d: Data) { data.append(d) }
}
