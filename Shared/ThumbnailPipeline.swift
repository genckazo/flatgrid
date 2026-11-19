import Foundation
import CoreGraphics
import ImageIO
import QuickLookThumbnailing
import CryptoKit
import UniformTypeIdentifiers

/// Lazy thumbnail pipeline: memory cache → disk cache → generate.
/// Bounded workers, newest request first, cancellable, in-flight requests de-duplicated.
final class ThumbnailPipeline: @unchecked Sendable {
    static let shared = ThumbnailPipeline()

    /// Longest-edge pixel sizes that thumbnails are produced at.
    static let buckets = [128, 256, 512, 1024]

    static func bucket(forPixelSide side: CGFloat) -> Int {
        buckets.first { CGFloat($0) >= side * 0.8 } ?? buckets[buckets.count - 1]
    }

    struct Token {
        fileprivate let key: String
        fileprivate let id: UInt64
    }

    struct Stats {
        var diskHits = 0
        var generated = 0
        var failed = 0
        var cancelled = 0
    }

    private final class ImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private enum JobState { case queued, running, finished }

    private final class Job {
        let key: String
        let item: MediaItem
        let bucket: Int
        var lowPriority: Bool
        var state = JobState.queued
        var waiters: [UInt64: (CGImage?) -> Void] = [:]
        init(key: String, item: MediaItem, bucket: Int, lowPriority: Bool) {
            self.key = key
            self.item = item
            self.bucket = bucket
            self.lowPriority = lowPriority
        }
    }

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var highQueue: [Job] = []
    private var lowQueue: [Job] = []
    private var running = 0
    private var nextID: UInt64 = 0
    private var failedKeys = Set<String>()
    private var _stats = Stats()
    private let maxConcurrent: Int
    private let workQueue = DispatchQueue(label: "flatgrid.thumbnails", qos: .userInitiated, attributes: .concurrent)
    private let memory = NSCache<NSString, ImageBox>()
    private var _cacheDirectory: URL?

    init() {
        maxConcurrent = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        #if os(macOS)
        memory.totalCostLimit = 320 * 1024 * 1024
        #else
        memory.totalCostLimit = 160 * 1024 * 1024
        #endif
    }

    var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return _stats
    }

    var cacheDirectory: URL {
        lock.lock()
        if let dir = _cacheDirectory { lock.unlock(); return dir }
        lock.unlock()
        let dir = AppPaths.thumbnailDirectory
        lock.lock(); _cacheDirectory = dir; lock.unlock()
        return dir
    }

    /// Forgets the resolved cache location (used when `AppPaths.overrideBase` changes).
    func resetLocation() {
        lock.lock(); _cacheDirectory = nil; lock.unlock()
        memory.removeAllObjects()
    }

    // MARK: Lookup

    private static func key(_ item: MediaItem, _ bucket: Int) -> String { "\(bucket)|\(item.cacheKey)" }

    /// Memory-only, synchronous. Safe to call from the main thread while scrolling.
    func cached(_ item: MediaItem, bucket: Int) -> CGImage? {
        memory.object(forKey: Self.key(item, bucket) as NSString)?.image
    }

    /// Any size already in memory, preferring the requested bucket, then larger, then smaller.
    func bestCached(_ item: MediaItem, preferring bucket: Int) -> CGImage? {
        if let exact = cached(item, bucket: bucket) { return exact }
        for candidate in Self.buckets.reversed() where candidate != bucket {
            if let hit = cached(item, bucket: candidate) { return hit }
        }
        return nil
    }

    // MARK: Requests

    /// Asks for a thumbnail. The completion always runs later, on the main thread.
    @discardableResult
    func request(
        _ item: MediaItem,
        bucket: Int,
        lowPriority: Bool = false,
        completion: @escaping (CGImage?) -> Void
    ) -> Token? {
        let key = Self.key(item, bucket)
        if let hit = memory.object(forKey: key as NSString)?.image {
            DispatchQueue.main.async { completion(hit) }
            return nil
        }
        lock.lock()
        if failedKeys.contains(key) {
            lock.unlock()
            DispatchQueue.main.async { completion(nil) }
            return nil
        }
        nextID += 1
        let id = nextID
        if let job = jobs[key] {
            job.waiters[id] = completion
            if !lowPriority && job.lowPriority && job.state == .queued {
                job.lowPriority = false
                highQueue.append(job)
            }
        } else {
            let job = Job(key: key, item: item, bucket: bucket, lowPriority: lowPriority)
            job.waiters[id] = completion
            jobs[key] = job
            if lowPriority { lowQueue.append(job) } else { highQueue.append(job) }
        }
        lock.unlock()
        pump()
        return Token(key: key, id: id)
    }

    func cancel(_ token: Token?) {
        guard let token else { return }
        lock.lock()
        if let job = jobs[token.key] {
            job.waiters[token.id] = nil
            if job.waiters.isEmpty && job.state == .queued {
                job.state = .finished
                jobs[token.key] = nil
                _stats.cancelled += 1
            }
        }
        lock.unlock()
    }

    func image(for item: MediaItem, bucket: Int) async -> CGImage? {
        await withCheckedContinuation { continuation in
            request(item, bucket: bucket) { continuation.resume(returning: $0) }
        }
    }

    private func pump() {
        lock.lock()
        while running < maxConcurrent {
            var next: Job?
            while let candidate = highQueue.popLast() {
                if candidate.state == .queued && !candidate.lowPriority { next = candidate; break }
            }
            if next == nil {
                while let candidate = lowQueue.popLast() {
                    if candidate.state == .queued && candidate.lowPriority { next = candidate; break }
                }
            }
            guard let job = next else { break }
            job.state = .running
            running += 1
            workQueue.async { [weak self] in autoreleasepool { self?.run(job) } }
        }
        // Cancelled entries pile up at the bottom of a LIFO stack; trim them occasionally.
        if highQueue.count > 4096 { highQueue.removeAll { $0.state != .queued } }
        if lowQueue.count > 4096 { lowQueue.removeAll { $0.state != .queued } }
        lock.unlock()
    }

    private func run(_ job: Job) {
        var image: CGImage?
        var fromDisk = false
        let fileURL = diskURL(forKey: job.key, bucket: job.bucket)

        if let disk = Self.readDisk(fileURL) {
            image = Self.displayReady(disk)
            fromDisk = true
        } else {
            lock.lock()
            let abandoned = job.waiters.isEmpty
            lock.unlock()
            if !abandoned {
                if let made = Self.generate(item: job.item, maxPixel: job.bucket) {
                    Self.writeDisk(made, to: fileURL)
                    image = Self.displayReady(made)
                }
            }
        }

        if let image {
            memory.setObject(ImageBox(image), forKey: job.key as NSString, cost: image.bytesPerRow * image.height)
        }

        lock.lock()
        let waiters = Array(job.waiters.values)
        job.waiters.removeAll()
        job.state = .finished
        jobs[job.key] = nil
        running -= 1
        if image == nil {
            if waiters.isEmpty { _stats.cancelled += 1 } else { failedKeys.insert(job.key); _stats.failed += 1 }
        } else if fromDisk {
            _stats.diskHits += 1
        } else {
            _stats.generated += 1
        }
        lock.unlock()

        if !waiters.isEmpty {
            DispatchQueue.main.async { for waiter in waiters { waiter(image) } }
        }
        pump()
    }

    // MARK: Disk cache

    private func diskURL(forKey key: String, bucket: Int) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory
            .appendingPathComponent("\(bucket)", isDirectory: true)
            .appendingPathComponent(String(hex.prefix(2)), isDirectory: true)
            .appendingPathComponent(hex + ".thumb")
    }

    private static func readDisk(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    private static func writeDisk(_ image: CGImage, to url: URL) {
        let opaque: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: opaque = true
        default: opaque = false
        }
        let type = (opaque ? UTType.jpeg : UTType.png).identifier as CFString
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (data as Data).write(to: url, options: .atomic)
    }

    func clearCache() {
        lock.lock()
        failedKeys.removeAll()
        lock.unlock()
        memory.removeAllObjects()
        let dir = cacheDirectory
        if let children = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for child in children { try? FileManager.default.removeItem(at: child) }
        }
    }

    func clearMemory() { memory.removeAllObjects() }

    func diskCacheSize() -> Int64 {
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: cacheDirectory, includingPropertiesForKeys: Array(keys)) else { return 0 }
        for case let url as URL in walker {
            if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: Display format

    /// Redraws a thumbnail into the pixel layout Core Animation takes as-is (8-bit BGRA, sRGB or
    /// Display P3). Without this, Core Animation converts every image on the main thread when it
    /// first appears, which is what stalls a fast scroll.
    static func displayReady(_ image: CGImage) -> CGImage {
        let opaque: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: opaque = true
        default: opaque = false
        }
        let alpha = opaque ? CGImageAlphaInfo.noneSkipFirst : CGImageAlphaInfo.premultipliedFirst
        let wide = image.colorSpace?.isWideGamutRGB ?? false
        guard let space = CGColorSpace(name: wide ? CGColorSpace.displayP3 : CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | alpha.rawValue
              ) else { return image }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    // MARK: Generation

    static func generate(item: MediaItem, maxPixel: Int) -> CGImage? {
        let usesImageIO = item.group == .image || item.group == .raw || item.fileExtension == "psd"
        if usesImageIO,
           let image = imageIOThumbnail(url: item.url, maxPixel: maxPixel, preferEmbedded: item.group == .raw) {
            return image
        }
        return quickLookThumbnail(url: item.url, maxPixel: maxPixel)
    }

    static func imageIOThumbnail(url: URL, maxPixel: Int, preferEmbedded: Bool) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        func make(_ creationKey: CFString) -> CGImage? {
            let options: [CFString: Any] = [
                creationKey: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }

        if preferEmbedded, let embedded = make(kCGImageSourceCreateThumbnailFromImageIfAbsent) {
            // RAW files carry a preview; use it unless it is much smaller than what was asked for.
            if max(embedded.width, embedded.height) * 10 >= maxPixel * 6 { return embedded }
        }
        return make(kCGImageSourceCreateThumbnailFromImageAlways)
    }

    static func quickLookThumbnail(url: URL, maxPixel: Int) -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxPixel, height: maxPixel),
            scale: 1,
            representationTypes: .thumbnail
        )
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            box.image = representation?.cgImage
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            QLThumbnailGenerator.shared.cancel(request)
            return nil
        }
        return box.image
    }

    private final class ResultBox: @unchecked Sendable {
        var image: CGImage?
    }
}
