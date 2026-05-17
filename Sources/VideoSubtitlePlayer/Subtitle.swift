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
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits text into display lines for bilingual rendering.
    /// Handles both explicit \n (merged tracks) and same-line "English. 中文" format.
    var bilingualLines: [String] {
        let t = cleanText
        if t.contains("\n") {
            return t.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        guard let splitIdx = t.firstIndex(where: { c in
            c.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        }), splitIdx > t.startIndex else { return [t] }
        let pre = String(t[..<splitIdx]).trimmingCharacters(in: .whitespaces)
        let suf = String(t[splitIdx...])
        let latinCount = pre.unicodeScalars.filter {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
        }.count
        guard latinCount >= 3, suf.count >= 2 else { return [t] }
        return [pre, suf]
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
