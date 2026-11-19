import Foundation
import UniformTypeIdentifiers

/// The four type groups the browser knows about.
enum MediaGroup: String, CaseIterable, Codable, Identifiable, Sendable {
    case image, video, raw, layered

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return "Images"
        case .video: return "Videos"
        case .raw: return "RAW"
        case .layered: return "Layered"
        }
    }

    var shortTitle: String {
        switch self {
        case .image: return "IMG"
        case .video: return "VID"
        case .raw: return "RAW"
        case .layered: return "LAY"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .raw: return "camera.aperture"
        case .layered: return "square.3.layers.3d"
        }
    }

    /// Layered documents are hidden until the user turns them on.
    var visibleByDefault: Bool { self != .layered }
}

enum MediaTypes {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "webp", "avif", "heic", "heif",
        "tif", "tiff", "gif", "bmp", "jp2", "j2k", "j2c", "jpc", "jpf", "jpx",
    ]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static let layeredExtensions: Set<String> = ["pdf", "psd", "ai", "procreate"]
    static let rawExtensions: Set<String> = [
        "dng", "raw", "cr2", "cr3", "crw", "nef", "nrw", "arw", "sr2", "srf", "raf",
        "rw2", "rwl", "orf", "ori", "pef", "ptx", "srw", "3fr", "fff", "iiq", "mos",
        "mrw", "erf", "kdc", "dcr", "x3f", "nefx",
    ]

    private static let lock = NSLock()
    private static var dynamicCache: [String: MediaGroup?] = [:]

    /// Group for a file extension (any case), or nil when the file is not media we show.
    /// Unknown extensions are checked once against the system type database so any RAW
    /// format the platform knows about is picked up too.
    static func group(forExtension rawExt: String) -> MediaGroup? {
        let ext = rawExt.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if rawExtensions.contains(ext) { return .raw }
        if videoExtensions.contains(ext) { return .video }
        if layeredExtensions.contains(ext) { return .layered }
        if ext.isEmpty || ext.count > 8 { return nil }

        lock.lock()
        if let hit = dynamicCache[ext] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        var result: MediaGroup?
        if let type = UTType(filenameExtension: ext), type.conforms(to: .rawImage) {
            result = .raw
        }
        lock.lock()
        dynamicCache[ext] = result
        lock.unlock()
        return result
    }
}

/// Lower-cased, diacritic-free form used on both sides of a search comparison.
func foldForSearch(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
}
