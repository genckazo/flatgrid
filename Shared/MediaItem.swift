import Foundation

/// One media file found under a root. Value type, cheap to copy, never mutated.
struct MediaItem: Hashable, Identifiable, Sendable {
    let url: URL
    let path: String
    let name: String
    let folderPath: String
    let group: MediaGroup
    let modified: Date
    let created: Date
    /// When the file arrived in its folder (Finder's "Date Added").
    let added: Date
    let size: Int64
    let tags: [String]
    /// Folded filename + Finder tags, built once at scan time.
    let searchKey: String
    /// Changes whenever the file's content plausibly changed, so cached thumbnails go stale.
    let cacheKey: String

    init(url: URL, path: String, name: String, folderPath: String, group: MediaGroup,
         modified: Date, created: Date, added: Date, size: Int64, tags: [String], searchKey: String) {
        self.url = url
        self.path = path
        self.name = name
        self.folderPath = folderPath
        self.group = group
        self.modified = modified
        self.created = created
        self.added = added
        self.size = size
        self.tags = tags
        self.searchKey = searchKey
        self.cacheKey = "\(path)|\(Int64(modified.timeIntervalSince1970 * 1000))|\(size)"
    }

    var id: String { path }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var folderName: String { (folderPath as NSString).lastPathComponent }

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
}
