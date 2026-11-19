import Foundation

/// Recursively enumerates a folder and returns every supported media file. Read-only.
enum FolderScanner {
    static let resourceKeys: [URLResourceKey] = {
        var keys: [URLResourceKey] = [
            .isRegularFileKey, .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey, .fileSizeKey,
        ]
        #if os(macOS)
        keys.append(.tagNamesKey)
        #endif
        return keys
    }()

    static func scan(
        root: URL,
        isCancelled: () -> Bool = { false },
        progress: ((Int) -> Void)? = nil
    ) -> [MediaItem] {
        let keySet = Set(resourceKeys)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var items: [MediaItem] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited % 512 == 0 {
                if isCancelled() { break }
                progress?(items.count)
            }
            let ext = url.pathExtension
            if ext.isEmpty { continue }
            guard let group = MediaTypes.group(forExtension: ext) else { continue }
            guard let values = try? url.resourceValues(forKeys: keySet),
                  values.isRegularFile == true else { continue }

            let name = url.lastPathComponent
            let modified = values.contentModificationDate ?? .distantPast
            #if os(macOS)
            let tags = values.tagNames ?? []
            #else
            let tags: [String] = []
            #endif
            let key = tags.isEmpty ? foldForSearch(name) : foldForSearch(name + " " + tags.joined(separator: " "))
            items.append(MediaItem(
                url: url,
                path: url.path,
                name: name,
                folderPath: url.deletingLastPathComponent().path,
                group: group,
                modified: modified,
                created: values.creationDate ?? modified,
                added: values.addedToDirectoryDate ?? values.creationDate ?? modified,
                size: Int64(values.fileSize ?? 0),
                tags: tags,
                searchKey: key
            ))
        }
        progress?(items.count)
        return items
    }
}
