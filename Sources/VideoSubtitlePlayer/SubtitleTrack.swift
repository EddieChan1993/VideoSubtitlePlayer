import Foundation

struct SubtitleTrack: Identifiable, Equatable, Hashable {
    let id: Int         // ffprobe global stream index
    let index: Int      // subtitle-only index (used for -map 0:s:N)
    let language: String?
    let title: String?

    var displayName: String {
        let lang = localizedLanguage ?? language?.uppercased() ?? "Track \(index + 1)"
        if let t = title, !t.isEmpty { return "\(lang) · \(t)" }
        return lang
    }

    private var localizedLanguage: String? {
        switch language?.lowercased() {
        case "chi", "zho", "zh", "cmn", "chs", "cht": return "中文"
        case "eng", "en":                              return "英文"
        case "jpn", "ja":                              return "日文"
        case "kor", "ko":                              return "韩文"
        case "fra", "fre", "fr":                       return "法文"
        case "spa", "es":                              return "西班牙文"
        default:                                        return nil
        }
    }

    var isChinese: Bool {
        ["chi","zho","zh","cmn","chs","cht"].contains(language?.lowercased() ?? "")
    }
    var isEnglish: Bool {
        ["eng","en"].contains(language?.lowercased() ?? "")
    }
}

enum SubtitleMode: Equatable, Hashable {
    case single(SubtitleTrack)
    case bilingual(SubtitleTrack, SubtitleTrack)  // primary first (shown on top)
}
