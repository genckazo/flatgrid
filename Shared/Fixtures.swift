import Foundation
import CoreGraphics
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Generates sample media inside the app's own directories: test folders for `--verify` on the Mac
/// and the optional sample library on iPhone. Never writes anywhere else.
enum Fixtures {
    struct Entry {
        let name: String
        let folder: String
        let group: MediaGroup
    }

    struct Manifest {
        let root: URL
        /// Media files, written by hand in ascending Finder name order.
        let entries: [Entry]
        /// Day offset per entry (same index), each one different.
        let dayOffsets: [Int]
        /// Folders in ascending path order.
        let folderOrder: [String]
        let decoys: [String]
        let taggedName: String
        let tag: String
        let keywordName: String
        let keyword: String
        var notes: [String]

        var expectedCounts: [MediaGroup: Int] {
            var counts: [MediaGroup: Int] = [:]
            for entry in entries { counts[entry.group, default: 0] += 1 }
            return counts
        }
    }

    // Hand-ordered: this literal order IS the expected "Name A–Z" result.
    static let entries: [Entry] = [
        Entry(name: "alder_1.jpg", folder: "alpha", group: .image),
        Entry(name: "alder_2.jpg", folder: "alpha", group: .image),
        Entry(name: "alder_10.jpg", folder: "alpha", group: .image),
        Entry(name: "birch.png", folder: "alpha/deep/deeper/deepest", group: .image),
        Entry(name: "cedar.tiff", folder: "alpha/deep/deeper/deepest", group: .image),
        Entry(name: "dogwood.gif", folder: "alpha/deep/deeper/deepest", group: .image),
        Entry(name: "elm.heic", folder: "beta", group: .image),
        Entry(name: "fir.bmp", folder: "beta", group: .image),
        Entry(name: "ginkgo.jp2", folder: "beta", group: .image),
        Entry(name: "hazel.webp", folder: "beta", group: .image),
        Entry(name: "ironwood.avif", folder: "beta", group: .image),
        Entry(name: "juniper.dng", folder: "beta/raw", group: .raw),
        Entry(name: "kapok.cr2", folder: "beta/raw", group: .raw),
        Entry(name: "larch.cr3", folder: "beta/raw", group: .raw),
        Entry(name: "maple.nef", folder: "beta/raw", group: .raw),
        Entry(name: "nutmeg.arw", folder: "beta/raw", group: .raw),
        Entry(name: "oak.raf", folder: "beta/raw", group: .raw),
        Entry(name: "pine.rw2", folder: "beta/raw", group: .raw),
        Entry(name: "quince.orf", folder: "beta/raw", group: .raw),
        Entry(name: "redwood.mov", folder: "gamma/video", group: .video),
        Entry(name: "spruce.mp4", folder: "gamma/video", group: .video),
        Entry(name: "teak.m4v", folder: "gamma/video", group: .video),
        Entry(name: "upas.pdf", folder: "gamma/layered", group: .layered),
        Entry(name: "viburnum.psd", folder: "gamma/layered", group: .layered),
        Entry(name: "walnut.ai", folder: "gamma/layered", group: .layered),
        Entry(name: "xylosma.procreate", folder: "gamma/layered", group: .layered),
        Entry(name: "YEW.JPG", folder: "delta", group: .image),
        Entry(name: "zebrawood.jpeg", folder: "delta", group: .image),
        Entry(name: "zelkova.tif", folder: "delta", group: .image),
    ]

    static let folderOrder = [
        "alpha", "alpha/deep/deeper/deepest", "beta", "beta/raw", "delta", "gamma/layered", "gamma/video",
    ]

    /// Files that must NOT appear in the grid.
    static let decoys = [
        "alpha/notes.txt", "delta/data.json", "delta/README", "delta/archive.zip", "delta/song.mp3",
        "alpha/.hidden.jpg", ".hiddendir/secret.png", "delta/Sample.app/Contents/Resources/inside.png",
    ]

    static let baseDate = Date(timeIntervalSince1970: 1_704_110_400) // 2024-01-01 12:00 UTC

    // MARK: Small fixture

    static func makeSmallFixture(at root: URL) async throws -> Manifest {
        let fm = FileManager.default
        var notes: [String] = []
        var offsets: [Int] = []
        let tagged = "cedar.tiff"
        let keyworded = "alder_2.jpg"
        let keyword = "quokkaword"
        let tag = "FlatGridVerifyTag"

        for (index, entry) in entries.enumerated() {
            let folder = root.appendingPathComponent(entry.folder, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(entry.name)
            let ext = (entry.name as NSString).pathExtension.lowercased()
            let image = makeImage(width: 320 + (index % 5) * 64, height: 240 + (index % 3) * 80, seed: index)

            switch ext {
            case "jpg", "jpeg":
                var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
                if entry.name == keyworded {
                    properties[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCKeywords: [keyword]]
                    properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "FlatGridCam"]
                }
                try write(encode(image, .jpeg, properties), to: url, what: entry.name)
            case "png": try write(encode(image, .png), to: url, what: entry.name)
            case "tif", "tiff": try write(encode(image, .tiff), to: url, what: entry.name)
            case "gif": try write(encode(image, .gif), to: url, what: entry.name)
            case "bmp": try write(encode(image, .bmp), to: url, what: entry.name)
            case "heic":
                if let data = encode(image, .heic) { try data.write(to: url) } else {
                    notes.append("\(entry.name): HEIC encoder unavailable, JPEG bytes written")
                    try write(encode(image, .jpeg), to: url, what: entry.name)
                }
            case "jp2":
                if let type = UTType("public.jpeg-2000"), let data = encode(image, type) { try data.write(to: url) } else {
                    notes.append("\(entry.name): JPEG-2000 encoder unavailable, JPEG bytes written")
                    try write(encode(image, .jpeg), to: url, what: entry.name)
                }
            case "webp", "avif":
                if let type = UTType(filenameExtension: ext), let data = encode(image, type) { try data.write(to: url) } else {
                    notes.append("\(entry.name): no system encoder for this format, JPEG bytes written")
                    try write(encode(image, .jpeg), to: url, what: entry.name)
                }
            case "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf":
                // No system RAW encoder exists; TIFF bytes stand in so the scan has a real file to find.
                try write(encode(image, .tiff), to: url, what: entry.name)
            case "mov", "mp4", "m4v":
                let type: AVFileType = ext == "mov" ? .mov : (ext == "mp4" ? .mp4 : .m4v)
                do {
                    try await writeVideo(to: url, fileType: type, seed: index)
                } catch {
                    notes.append("\(entry.name): video encoder failed (\(error.localizedDescription)), placeholder bytes written")
                    try Data("flatgrid placeholder video".utf8).write(to: url)
                }
            case "pdf", "ai":
                try writePDF(to: url, seed: index)
            case "psd":
                if let type = UTType("com.adobe.photoshop-image"), let data = encode(image, type) { try data.write(to: url) } else {
                    notes.append("\(entry.name): PSD encoder unavailable, TIFF bytes written")
                    try write(encode(image, .tiff), to: url, what: entry.name)
                }
            default:
                try Data("PK\u{03}\u{04} flatgrid placeholder".utf8).write(to: url)
            }

            // Files arrive one after another, so "date added" order is the order of this list.
            try await Task.sleep(nanoseconds: 15_000_000)
            let offset = (index * 11) % entries.count
            offsets.append(offset)
            let date = baseDate.addingTimeInterval(Double(offset) * 86_400)
            try fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        }

        for decoy in decoys {
            let url = root.appendingPathComponent(decoy)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let ext = url.pathExtension.lowercased()
            if ext == "jpg" || ext == "png" {
                try write(encode(makeImage(width: 64, height: 64, seed: 99), ext == "png" ? .png : .jpeg), to: url, what: decoy)
            } else {
                try Data("not media".utf8).write(to: url)
            }
        }

        #if os(macOS)
        let taggedURL = root.appendingPathComponent("alpha/deep/deeper/deepest").appendingPathComponent(tagged)
        try (taggedURL as NSURL).setResourceValue([tag] as NSArray, forKey: .tagNamesKey)
        #endif

        return Manifest(
            root: root, entries: entries, dayOffsets: offsets, folderOrder: folderOrder, decoys: decoys,
            taggedName: tagged, tag: tag, keywordName: keyworded, keyword: keyword, notes: notes
        )
    }

    // MARK: Large fixture

    /// `count` real JPEG files spread over nested folders.
    static func makeLargeFixture(at root: URL, count: Int, folders: Int) throws {
        let sizes = [(640, 480), (480, 640), (800, 600), (600, 600), (1024, 576), (432, 768)]
        var bases: [Data] = []
        for index in 0..<48 {
            let size = sizes[index % sizes.count]
            let image = makeImage(width: size.0, height: size.1, seed: 1000 + index)
            guard let data = encode(image, .jpeg, [kCGImageDestinationLossyCompressionQuality: 0.7]) else {
                throw NSError(domain: "Fixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "JPEG encode failed"])
            }
            bases.append(data)
        }
        let fm = FileManager.default
        for folder in 0..<folders {
            try fm.createDirectory(at: largeFolderURL(root, folder), withIntermediateDirectories: true)
        }
        let failures = Counter()
        let immutableBases = bases
        DispatchQueue.concurrentPerform(iterations: count) { index in
            let url = largeFolderURL(root, index % folders).appendingPathComponent(String(format: "img_%05d.jpg", index))
            do { try immutableBases[index % immutableBases.count].write(to: url) } catch { failures.increment() }
        }
        if failures.value > 0 {
            throw NSError(domain: "Fixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(failures.value) fixture writes failed"])
        }
    }

    private static func largeFolderURL(_ root: URL, _ folder: Int) -> URL {
        root.appendingPathComponent(String(format: "batch_%02d/set_%03d", folder / 20, folder), isDirectory: true)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    // MARK: Encoders

    static func makeImage(width: Int, height: Int, seed: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        var generator = SplitMix64(seed: UInt64(seed) &* 7919 &+ 17)
        func unit() -> CGFloat { CGFloat(generator.next() % 1000) / 1000 }
        let colors = [
            CGColor(red: unit(), green: unit(), blue: unit(), alpha: 1),
            CGColor(red: unit(), green: unit(), blue: unit(), alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        for _ in 0..<6 {
            context.setFillColor(CGColor(red: unit(), green: unit(), blue: unit(), alpha: 0.75))
            let w = unit() * CGFloat(width) * 0.4 + 12
            let h = unit() * CGFloat(height) * 0.4 + 12
            let rect = CGRect(x: unit() * CGFloat(width) - w / 4, y: unit() * CGFloat(height) - h / 4, width: w, height: h)
            if generator.next() % 2 == 0 { context.fillEllipse(in: rect) } else { context.fill(rect) }
        }
        return context.makeImage()!
    }

    static func encode(_ image: CGImage, _ type: UTType, _ properties: [CFString: Any] = [:]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return data as Data
    }

    private static func write(_ data: Data?, to url: URL, what: String) throws {
        guard let data else {
            throw NSError(domain: "Fixtures", code: 3, userInfo: [NSLocalizedDescriptionKey: "could not encode \(what)"])
        }
        try data.write(to: url)
    }

    private static func writePDF(to url: URL, seed: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 420, height: 300)
        let info = [kCGPDFContextTitle: "FlatGrid fixture \(seed)"] as CFDictionary
        guard let context = CGContext(url as CFURL, mediaBox: &box, info) else {
            throw NSError(domain: "Fixtures", code: 4, userInfo: [NSLocalizedDescriptionKey: "could not create PDF"])
        }
        context.beginPDFPage(nil)
        context.draw(makeImage(width: 420, height: 300, seed: seed), in: box)
        context.endPDFPage()
        context.closePDF()
    }

    private static func writeVideo(to url: URL, fileType: AVFileType, seed: Int) async throws {
        let width = 320, height = 240
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else {
            throw NSError(domain: "Fixtures", code: 5, userInfo: [NSLocalizedDescriptionKey: "writer rejected input"])
        }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Fixtures", code: 6) }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<12 {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
                waited += 1
                if waited > 1000 { throw NSError(domain: "Fixtures", code: 7, userInfo: [NSLocalizedDescriptionKey: "encoder stalled"]) }
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw NSError(domain: "Fixtures", code: 8) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                let pixels = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = y * rowBytes + x * 4
                        pixels[offset] = UInt8((x + frame * 12 + seed * 30) % 256)
                        pixels[offset + 1] = UInt8((y + frame * 6) % 256)
                        pixels[offset + 2] = UInt8((seed * 40 + frame * 10) % 256)
                        pixels[offset + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 12)) {
                throw writer.error ?? NSError(domain: "Fixtures", code: 9)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "Fixtures", code: 10) }
    }

    // MARK: Integrity snapshot

    struct FileState: Equatable {
        let sha256: String
        let size: Int
        let modified: TimeInterval
        let attributes: [String]
    }

    /// Hash, size, modification time and extended-attribute names of every entry under `root`
    /// (hidden files and package contents included), keyed by relative path.
    static func snapshot(of root: URL) -> [String: FileState] {
        var result: [String: FileState] = [:]
        let rootPath = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(atPath: rootPath) else { return result }
        for case let relative as String in walker {
            let path = rootPath + "/" + relative
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            var digest = "dir"
            if !isDirectory.boolValue {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) {
                    digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                } else {
                    digest = "unreadable"
                }
            }
            result[relative] = FileState(
                sha256: digest, size: isDirectory.boolValue ? 0 : size, modified: modified,
                attributes: extendedAttributes(path)
            )
        }
        return result
    }

    private static func extendedAttributes(_ path: String) -> [String] {
        let length = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: length)
        let read = listxattr(path, &buffer, length, XATTR_NOFOLLOW)
        guard read > 0 else { return [] }
        let names = buffer.prefix(read).split(separator: 0).map { String(cString: Array($0) + [0]) }
        return names.map { name in "\(name)=\(getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW))" }.sorted()
    }
}
