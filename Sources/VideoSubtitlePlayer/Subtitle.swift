import Foundation

struct Subtitle: Identifiable, Equatable {
    let id: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String

    var cleanText: String {
        var s = text
        // Strip HTML tags
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Strip ASS override codes {…}
        s = s.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var startTimeString: String { formatTime(startTime) }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Reference-type wrapper around Data so it can be safely shared across
/// readabilityHandler / terminationHandler closures without Swift concurrency errors.
final class DataBox: @unchecked Sendable {
    private(set) var data = Data()
    func append(_ d: Data) { data.append(d) }
}
