import Foundation
import ImageIO
import AVFoundation
import PDFKit
#if os(macOS)
import CoreServices
#endif

struct InfoRow: Identifiable, Hashable {
    let label: String
    let value: String
    var id: String { label }
}

/// Reads metadata that already exists in a file. Nothing is analysed, inferred or written.
enum MetadataReader {
    // MARK: Search text

    /// Folded text built from metadata fields stored in the file, used as extra search haystack.
    static func searchText(for item: MediaItem) -> String {
        var parts: [String] = []
        switch item.group {
        case .image, .raw:
            parts += imageStrings(item.url)
        case .layered:
            switch item.fileExtension {
            case "pdf", "ai": parts += pdfStrings(item.url)
            case "psd": parts += imageStrings(item.url)
            default: break
            }
        case .video:
            break
        }
        #if os(macOS)
        parts += spotlightStrings(item.url)
        #endif
        return foldForSearch(parts.joined(separator: " "))
    }

    private static func properties(_ url: URL) -> [CFString: Any]? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else { return nil }
        return props
    }

    private static func strings(in dictionary: [CFString: Any]?, keys: [CFString]) -> [String] {
        guard let dictionary else { return [] }
        var out: [String] = []
        for key in keys {
            switch dictionary[key] {
            case let text as String where !text.isEmpty: out.append(text)
            case let list as [String]: out += list
            default: break
            }
        }
        return out
    }

    private static func imageStrings(_ url: URL) -> [String] {
        guard let props = properties(url) else { return [] }
        var out: [String] = []
        out += strings(in: props[kCGImagePropertyTIFFDictionary] as? [CFString: Any], keys: [
            kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFArtist,
            kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFImageDescription, kCGImagePropertyTIFFSoftware,
        ])
        out += strings(in: props[kCGImagePropertyExifDictionary] as? [CFString: Any], keys: [
            kCGImagePropertyExifLensModel, kCGImagePropertyExifLensMake,
            kCGImagePropertyExifUserComment, kCGImagePropertyExifDateTimeOriginal,
        ])
        out += strings(in: props[kCGImagePropertyIPTCDictionary] as? [CFString: Any], keys: [
            kCGImagePropertyIPTCKeywords, kCGImagePropertyIPTCCaptionAbstract, kCGImagePropertyIPTCObjectName,
            kCGImagePropertyIPTCHeadline, kCGImagePropertyIPTCByline, kCGImagePropertyIPTCCity,
            kCGImagePropertyIPTCProvinceState, kCGImagePropertyIPTCCountryPrimaryLocationName,
            kCGImagePropertyIPTCCredit, kCGImagePropertyIPTCSource,
        ])
        out += strings(in: props[kCGImagePropertyPNGDictionary] as? [CFString: Any], keys: [
            kCGImagePropertyPNGTitle, kCGImagePropertyPNGDescription, kCGImagePropertyPNGAuthor,
            kCGImagePropertyPNGComment, kCGImagePropertyPNGCopyright,
        ])
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            out.append("\(w)x\(h)")
        }
        return out
    }

    private static func pdfStrings(_ url: URL) -> [String] {
        guard let attributes = PDFDocument(url: url)?.documentAttributes else { return [] }
        var out: [String] = []
        for key in [PDFDocumentAttribute.titleAttribute, .authorAttribute, .subjectAttribute, .creatorAttribute] {
            if let text = attributes[key] as? String, !text.isEmpty { out.append(text) }
        }
        if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            out += keywords
        } else if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] as? String {
            out.append(keywords)
        }
        return out
    }

    #if os(macOS)
    /// Finder comment, title, authors and keywords as already indexed by the system.
    private static func spotlightStrings(_ url: URL) -> [String] {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return [] }
        var out: [String] = []
        for name in [kMDItemFinderComment, kMDItemTitle, kMDItemDescription, kMDItemAuthors, kMDItemKeywords] {
            switch MDItemCopyAttribute(item, name) {
            case let text as String where !text.isEmpty: out.append(text)
            case let list as [String]: out += list
            default: break
            }
        }
        return out
    }
    #endif

    // MARK: Info panel

    static func details(for item: MediaItem) async -> [InfoRow] {
        var rows: [InfoRow] = []
        let kind = item.fileExtension.uppercased()
        rows.append(InfoRow(label: "Kind", value: kind.isEmpty ? item.group.title : "\(kind) · \(item.group.title)"))
        rows.append(InfoRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)))

        if item.group == .video {
            let asset = AVURLAsset(url: item.url)
            if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
                rows.append(InfoRow(label: "Duration", value: formatDuration(duration.seconds)))
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let fitted = size.applying(transform)
                rows.append(InfoRow(label: "Dimensions", value: "\(Int(abs(fitted.width))) × \(Int(abs(fitted.height)))"))
                if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                    rows.append(InfoRow(label: "Frame rate", value: String(format: "%.2f fps", rate)))
                }
            }
        } else if let size = ImageLoader.pixelSize(of: item) {
            rows.append(InfoRow(label: "Dimensions", value: "\(Int(size.width)) × \(Int(size.height))"))
        }

        if item.group == .image || item.group == .raw, let props = properties(item.url) {
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let camera = [tiff?[kCGImagePropertyTIFFMake] as? String, tiff?[kCGImagePropertyTIFFModel] as? String]
                .compactMap { $0 }.joined(separator: " ")
            if !camera.isEmpty { rows.append(InfoRow(label: "Camera", value: camera)) }
            if let lens = exif?[kCGImagePropertyExifLensModel] as? String, !lens.isEmpty {
                rows.append(InfoRow(label: "Lens", value: lens))
            }
            var exposure: [String] = []
            if let focal = exif?[kCGImagePropertyExifFocalLength] as? Double { exposure.append(String(format: "%.0f mm", focal)) }
            if let aperture = exif?[kCGImagePropertyExifFNumber] as? Double { exposure.append(String(format: "ƒ/%.1f", aperture)) }
            if let time = exif?[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
                exposure.append(time >= 1 ? String(format: "%.1f s", time) : "1/\(Int((1 / time).rounded())) s")
            }
            if let iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
            if !exposure.isEmpty { rows.append(InfoRow(label: "Exposure", value: exposure.joined(separator: "  "))) }
            if let taken = exif?[kCGImagePropertyExifDateTimeOriginal] as? String { rows.append(InfoRow(label: "Taken", value: taken)) }
            if let profile = props[kCGImagePropertyProfileName] as? String { rows.append(InfoRow(label: "Colour profile", value: profile)) }
            let keywords = strings(in: props[kCGImagePropertyIPTCDictionary] as? [CFString: Any], keys: [kCGImagePropertyIPTCKeywords])
            if !keywords.isEmpty { rows.append(InfoRow(label: "Keywords", value: keywords.joined(separator: ", "))) }
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        rows.append(InfoRow(label: "Created", value: formatter.string(from: item.created)))
        rows.append(InfoRow(label: "Modified", value: formatter.string(from: item.modified)))
        if !item.tags.isEmpty { rows.append(InfoRow(label: "Tags", value: item.tags.joined(separator: ", "))) }
        rows.append(InfoRow(label: "Folder", value: item.folderPath))
        return rows
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
