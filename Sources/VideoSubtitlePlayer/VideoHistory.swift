import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: String { videoPath }
    let videoPath: String
    let videoTitle: String
    var lastOpened: Date
    var externalSubtitlePaths: [String]
}

final class VideoHistory: ObservableObject {
    static let shared = VideoHistory()
    private static let defaultsKey = "videoHistory_v1"

    @Published private(set) var entries: [HistoryEntry] = []

    private init() { load() }

    func record(videoURL: URL) {
        let path = videoURL.path
        let preserved = entries.first { $0.videoPath == path }?.externalSubtitlePaths ?? []
        var list = entries.filter { $0.videoPath != path }
        list.insert(HistoryEntry(videoPath: path,
                                  videoTitle: videoURL.deletingPathExtension().lastPathComponent,
                                  lastOpened: Date(),
                                  externalSubtitlePaths: preserved), at: 0)
        entries = Array(list.prefix(50))
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        ThumbnailCache.shared.remove(for: entry.videoPath)
        save()
    }

    func clearAll() {
        ThumbnailCache.shared.removeAll(for: entries.map { $0.videoPath })
        entries = []
        save()
    }

    func addSubtitle(_ url: URL, forVideo videoURL: URL) {
        let path = videoURL.path
        guard let idx = entries.firstIndex(where: { $0.videoPath == path }) else { return }
        guard !entries[idx].externalSubtitlePaths.contains(url.path) else { return }
        entries[idx].externalSubtitlePaths.append(url.path)
        save()
    }

    func removeSubtitle(_ subPath: String, forVideo videoURL: URL) {
        let path = videoURL.path
        guard let idx = entries.firstIndex(where: { $0.videoPath == path }) else { return }
        entries[idx].externalSubtitlePaths.removeAll { $0 == subPath }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }
}
