import Foundation

/// Every location the app is allowed to write to. Nothing outside these is ever written.
enum AppPaths {
    /// Set by `--verify` so a test run never touches the real settings, favorites or cache.
    nonisolated(unsafe) static var overrideBase: URL?

    static var supportDirectory: URL {
        let base: URL
        if let overrideBase {
            base = overrideBase.appendingPathComponent("Support", isDirectory: true)
        } else {
            base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FlatGrid", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var thumbnailDirectory: URL {
        let base: URL
        if let overrideBase {
            base = overrideBase.appendingPathComponent("Thumbnails", isDirectory: true)
        } else {
            base = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FlatGrid/Thumbnails", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var favoritesFile: URL { supportDirectory.appendingPathComponent("favorites.json") }
    static var rootsFile: URL { supportDirectory.appendingPathComponent("roots.json") }
}
