import Foundation

/// Favorites live in one JSON file in the app's own support directory. Each entry is keyed by a
/// file bookmark, so a favorite survives the file being renamed or moved. Nothing is ever
/// written to the favorited file itself.
final class FavoritesStore {
    struct Entry: Codable {
        var bookmark: Data
        var path: String
        var added: Date
    }

    private var entries: [String: Entry] = [:]
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            for entry in stored { entries[entry.path] = entry }
        }
    }

    var paths: Set<String> { Set(entries.keys) }
    var count: Int { entries.count }

    func contains(_ path: String) -> Bool { entries[path] != nil }

    func bookmark(for path: String) -> Data? { entries[path]?.bookmark }

    /// Adds or removes a favorite. Returns the new state.
    @discardableResult
    func toggle(_ item: MediaItem) -> Bool {
        if entries[item.path] != nil {
            entries[item.path] = nil
            save()
            return false
        }
        let bookmark = (try? item.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        entries[item.path] = Entry(bookmark: bookmark, path: item.path, added: Date())
        save()
        return true
    }

    /// Follows bookmarks for favorites whose stored path is no longer in the library, so a file
    /// that was renamed or moved stays a favorite. Returns true when something changed.
    @discardableResult
    func reconcile(knownPaths: Set<String>) -> Bool {
        var changed = false
        for (path, entry) in entries where !knownPaths.contains(path) && !entry.bookmark.isEmpty {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: entry.bookmark,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            let newPath = url.path
            guard newPath != path, knownPaths.contains(newPath), entries[newPath] == nil else { continue }
            entries[path] = nil
            entries[newPath] = Entry(bookmark: entry.bookmark, path: newPath, added: entry.added)
            changed = true
        }
        if changed { save() }
        return changed
    }

    private func save() {
        let list = entries.values.sorted { $0.added < $1.added }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
