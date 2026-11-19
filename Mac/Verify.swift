import AppKit
import QuartzCore

/// `FlatGrid --verify`: builds fixtures, exercises the real scan / query / thumbnail / grid code
/// and prints PASS or FAIL per check. Uses its own settings, favorites and cache, never the user's.
enum VerifyRunner {
    private static var delegate: VerifyDelegate?

    @MainActor
    static func launch() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = VerifyDelegate()
        self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

final class VerifyDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let passed = await Verify().run()
            fflush(stdout)
            exit(passed ? 0 : 1)
        }
    }
}

@MainActor
final class Verify {
    private var results: [(name: String, passed: Bool, detail: String)] = []
    private let quick = CommandLine.arguments.contains("--quick")
    private let keep = CommandLine.arguments.contains("--keep")

    private func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        results.append((name, passed, detail))
        print("[\(passed ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        fflush(stdout)
    }

    private func note(_ text: String) {
        print("       \(text)")
        fflush(stdout)
    }

    private func pause(_ milliseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    /// Lets queued main-thread work run, then waits for the model's background work.
    private func settle(_ model: LibraryModel) async {
        for _ in 0..<3 {
            await pause(40)
            await model.settle()
        }
    }

    func run() async -> Bool {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("FlatGridVerify-\(UUID().uuidString)", isDirectory: true)
        let appData = base.appendingPathComponent("AppData", isDirectory: true)
        let fixtureRoot = base.appendingPathComponent("Fixture", isDirectory: true)
        let largeRoot = base.appendingPathComponent("Large", isDirectory: true)
        let suiteName = "flatgrid.verify.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            if !keep { try? fm.removeItem(at: base) }
        }

        print("FlatGrid --verify")
        print("  macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("  sandboxed: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")
        print("  work dir: \(base.path)")
        fflush(stdout)

        do {
            try fm.createDirectory(at: appData, withIntermediateDirectories: true)
        } catch {
            check("setup", false, "cannot create work dir: \(error.localizedDescription)")
            return false
        }
        AppPaths.overrideBase = appData
        ThumbnailPipeline.shared.resetLocation()
        let pipeline = ThumbnailPipeline.shared

        // ---------------------------------------------------------------- 1. fixture
        let manifest: Fixtures.Manifest
        do {
            manifest = try await Fixtures.makeSmallFixture(at: fixtureRoot)
        } catch {
            check("1 fixture tree generated", false, error.localizedDescription)
            return summary()
        }
        let expected = manifest.expectedCounts
        let expectedTotal = manifest.entries.count
        check("1 fixture tree generated", true,
              "\(expectedTotal) media files in \(manifest.folderOrder.count) folders (4 levels deep), \(manifest.decoys.count) decoys; "
              + MediaGroup.allCases.map { "\($0.rawValue)=\(expected[$0] ?? 0)" }.joined(separator: " "))
        for line in manifest.notes { note(line) }

        // Integrity baseline, taken before the app code touches anything.
        let before = Fixtures.snapshot(of: fixtureRoot)

        // ---------------------------------------------------------------- 2. counts
        let scanned = FolderScanner.scan(root: fixtureRoot)
        var scannedCounts: [MediaGroup: Int] = [:]
        for item in scanned { scannedCounts[item.group, default: 0] += 1 }
        for group in MediaGroup.allCases {
            check("2 scan count: \(group.rawValue)", scannedCounts[group] == expected[group],
                  "found \(scannedCounts[group] ?? 0), fixture has \(expected[group] ?? 0)")
        }
        let decoyNames = Set(manifest.decoys.map { ($0 as NSString).lastPathComponent })
        let leaked = scanned.filter { decoyNames.contains($0.name) }.map(\.name)
        check("2 decoys, hidden files and package contents excluded", leaked.isEmpty && scanned.count == expectedTotal,
              leaked.isEmpty ? "scan total \(scanned.count)" : "leaked: \(leaked.joined(separator: ", "))")

        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("setup", false, "cannot create defaults suite")
            return summary()
        }
        let settings = AppSettings(defaults: defaults)
        let favorites = FavoritesStore(fileURL: AppPaths.favoritesFile)
        let model = LibraryModel(settings: settings, favorites: favorites, rootsFile: AppPaths.rootsFile)
        model.addFolder(fixtureRoot)
        await model.rescan().value
        await settle(model)

        let layeredCount = expected[.layered] ?? 0
        check("2 layered files hidden by default", model.visible.count == expectedTotal - layeredCount,
              "grid model shows \(model.visible.count), expected \(expectedTotal - layeredCount)")
        settings.visibleGroups = Set(MediaGroup.allCases)
        await settle(model)
        check("2 grid model count with all groups on", model.visible.count == expectedTotal,
              "grid model shows \(model.visible.count), fixture has \(expectedTotal)")

        let grid = GridViewController()
        grid.pipeline = pipeline
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "FlatGrid verify"
        window.contentViewController = grid
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        grid.layout.targetSide = 150
        grid.setItems(model.visible, selected: nil, resetScroll: true)
        await pause(400)
        let gridCount = grid.itemCount
        let onScreen = grid.visibleTileCount
        check("2 real grid view item count", gridCount == expectedTotal && onScreen == expectedTotal,
              "grid view holds \(gridCount) items, \(onScreen) tiles laid out on screen")

        // ---------------------------------------------------------------- 4. sort orders
        let names = manifest.entries.map(\.name)
        func shown() -> [String] { model.visible.map(\.name) }
        func firstDifference(_ a: [String], _ b: [String]) -> String {
            for (index, pair) in zip(a, b).enumerated() where pair.0 != pair.1 {
                return "first difference at \(index): got \(pair.0), expected \(pair.1)"
            }
            return a.count == b.count ? "identical" : "lengths differ \(a.count) vs \(b.count)"
        }
        func expectOrder(_ mode: SortMode, _ expectedNames: [String]) async {
            model.setSort(mode)
            await settle(model)
            let got = shown()
            check("4 sort \(mode.rawValue) \(mode.title)", got == expectedNames, firstDifference(got, expectedNames))
        }
        // 1 Date created: newest first (fixture dates were set explicitly, one per file).
        let byDateAscending = names.indices.sorted { manifest.dayOffsets[$0] < manifest.dayOffsets[$1] }.map { names[$0] }
        await expectOrder(.dateCreated, byDateAscending.reversed())
        // 2 Date added: newest first (files were written one after another in list order).
        await expectOrder(.dateAdded, names.reversed())
        // 3 Name: the hand-written list order.
        await expectOrder(.name, names)
        // 4 Type: by extension, then name.
        func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }
        let byType = names.indices.sorted { ext(names[$0]) != ext(names[$1]) ? ext(names[$0]) < ext(names[$1]) : $0 < $1 }.map { names[$0] }
        await expectOrder(.type, byType)
        var byFolder: [String] = []
        for folder in manifest.folderOrder {
            byFolder += manifest.entries.filter { $0.folder == folder }.map(\.name)
        }
        await expectOrder(.folder, byFolder)

        model.setSort(.random)
        await settle(model)
        let shuffleA = shown()
        let seedA = model.randomSeed
        let replay = LibraryQuery.sorted(model.allItems, by: .random, seed: seedA).map(\.name)
        model.setSort(.random)
        await settle(model)
        let shuffleB = shown()
        check("4 sort 6 Random",
              Set(shuffleA) == Set(names) && shuffleA.count == names.count && shuffleA != names
              && shuffleA == replay && shuffleB != shuffleA && Set(shuffleB) == Set(names),
              "permutation of all \(names.count), differs from name order, same seed reproduces it, pressing 6 again reshuffles")

        // Folder jumps (⌘↑ / ⌘↓) on the folder-sorted list.
        model.setSort(.folder)
        await settle(model)
        var jumpsOK = true
        var cursor = 0
        var visitedFolders = [model.visible[0].folderName]
        while let next = model.folderJumpTarget(from: cursor, forward: true) {
            if model.visible[next].folderPath == model.visible[cursor].folderPath { jumpsOK = false }
            if next > 0, model.visible[next - 1].folderPath == model.visible[next].folderPath { jumpsOK = false }
            cursor = next
            visitedFolders.append(model.visible[next].folderName)
        }
        let backFromEnd = model.folderJumpTarget(from: model.visible.count - 1, forward: false)
        check("4 next/previous folder jumps", jumpsOK && visitedFolders.count == manifest.folderOrder.count && backFromEnd != nil,
              "visited \(visitedFolders.count) folders in order, expected \(manifest.folderOrder.count)")

        // ---------------------------------------------------------------- 5. search
        model.setSort(.name)
        await settle(model)
        func search(_ text: String) async -> [String] {
            model.searchText = text
            await settle(model)
            return shown()
        }
        let tagHits = await search(manifest.tag)
        check("5 search finds the Finder-tagged file", tagHits == [manifest.taggedName],
              "query “\(manifest.tag)” → \(tagHits)")
        let nameHits = await search("alder")
        check("5 search by filename", nameHits == ["alder_1.jpg", "alder_2.jpg", "alder_10.jpg"], "query “alder” → \(nameHits)")
        let caseHits = await search("ZEBRAWOOD")
        check("5 search ignores case", caseHits == ["zebrawood.jpeg"], "query “ZEBRAWOOD” → \(caseHits)")
        let keywordHits = await search(manifest.keyword)
        check("5 search by metadata stored in the file (IPTC keyword)", keywordHits == [manifest.keywordName],
              "query “\(manifest.keyword)” → \(keywordHits)")
        let noHits = await search("no-such-thing-xyzzy")
        check("5 search with no match shows nothing", noHits.isEmpty, "\(noHits.count) results")
        _ = await search("")

        // ---------------------------------------------------------------- favorites
        let picks = [0, 5, 12, 20, 24].map { model.visible[$0] }
        for item in picks { model.toggleFavorite(item) }
        model.favoritesOnly = true
        await settle(model)
        let favoriteNames = shown()
        check("favorites filter", Set(favoriteNames) == Set(picks.map(\.name)) && favoriteNames.count == picks.count,
              "favorites-only grid shows \(favoriteNames)")
        model.toggleFavorite(picks[0])
        await settle(model)
        let reloaded = FavoritesStore(fileURL: AppPaths.favoritesFile)
        let bookmarkOK = picks.dropFirst().allSatisfy { item in
            guard let data = reloaded.bookmark(for: item.path), !data.isEmpty else { return false }
            var stale = false
            let resolved = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            return resolved?.resolvingSymlinksInPath().path == item.url.resolvingSymlinksInPath().path
        }
        check("favorites persist, keyed by file bookmark", reloaded.count == picks.count - 1 && model.visible.count == picks.count - 1 && bookmarkOK,
              "\(reloaded.count) reloaded from disk, bookmarks resolve to the files: \(bookmarkOK)")
        let favoritesPath = AppPaths.favoritesFile.resolvingSymlinksInPath().path
        check("favorites stored outside the user's folders",
              !favoritesPath.hasPrefix(fixtureRoot.resolvingSymlinksInPath().path) && fm.fileExists(atPath: favoritesPath),
              favoritesPath.replacingOccurrences(of: base.resolvingSymlinksInPath().path, with: "<work dir>"))
        model.favoritesOnly = false
        await settle(model)

        // ---------------------------------------------------------------- thumbnails, decode, viewer
        var rendered: [MediaGroup: Int] = [:]
        var failedNames: [String] = []
        for item in model.allItems {
            let small = await pipeline.image(for: item, bucket: 128)
            let large = await pipeline.image(for: item, bucket: 512)
            if small != nil && large != nil { rendered[item.group, default: 0] += 1 } else { failedNames.append(item.name) }
        }
        note("thumbnails rendered: " + MediaGroup.allCases.map { "\($0.rawValue) \(rendered[$0] ?? 0)/\(expected[$0] ?? 0)" }.joined(separator: ", "))
        if !failedNames.isEmpty { note("no thumbnail for: \(failedNames.joined(separator: ", ")) (placeholder bytes, expected)") }
        check("thumbnails for every real image fixture", (rendered[.image] ?? 0) == (expected[.image] ?? 0),
              "\(rendered[.image] ?? 0) of \(expected[.image] ?? 0) images")
        check("thumbnails for every video fixture", (rendered[.video] ?? 0) == (expected[.video] ?? 0),
              "\(rendered[.video] ?? 0) of \(expected[.video] ?? 0) videos")

        var decoded = 0
        for item in model.allItems where item.group != .video {
            let image = await Task.detached { ImageLoader.load(item, maxPixel: nil) }.value
            if image != nil { decoded += 1 }
            _ = await MetadataReader.details(for: item)
        }
        note("full-size decodes succeeded for \(decoded) of \(model.allItems.filter { $0.group != .video }.count) non-video files")

        let viewer = ViewerHostView(frame: grid.view.bounds)
        viewer.autoresizingMask = [.width, .height]
        grid.view.addSubview(viewer)
        if let photo = model.allItems.first(where: { $0.name == "alder_10.jpg" }) {
            viewer.update(item: photo, turns: 0, actualSize: false, autoplay: false, muted: true)
            await pause(350)
            viewer.update(item: photo, turns: 1, actualSize: true, autoplay: false, muted: true)
            await pause(350)
        }
        if let clip = model.allItems.first(where: { $0.group == .video }) {
            viewer.update(item: clip, turns: 0, actualSize: false, autoplay: true, muted: true)
            await pause(900)
        }
        viewer.update(item: nil, turns: 0, actualSize: false, autoplay: false, muted: true)
        viewer.removeFromSuperview()

        // ---------------------------------------------------------------- 3. checksums
        let after = Fixtures.snapshot(of: fixtureRoot)
        var changed: [String] = []
        for (path, state) in before where after[path] != state { changed.append(path) }
        let added = after.keys.filter { before[$0] == nil }
        check("3 every fixture file unchanged after scan + thumbnails + decode + viewer + favorite + search + sort",
              changed.isEmpty && added.isEmpty && before.count == after.count,
              changed.isEmpty && added.isEmpty
                  ? "\(before.count) entries compared: SHA-256, size, modification time and extended attributes identical; no files added"
                  : "changed: \(changed.sorted().prefix(5)) added: \(added.sorted().prefix(5))")

        let topLevel = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).sorted()
        check("3 app wrote only inside its own data directory", Set(topLevel).isSubset(of: ["AppData", "Fixture"]),
              "work dir holds \(topLevel); thumbnails + favorites + roots are under AppData")

        // ---------------------------------------------------------------- 6. 10,000 images
        if quick {
            note("--quick given: 10,000-image scroll test skipped")
        } else {
            await largeTest(largeRoot: largeRoot, settings: settings, grid: grid, pipeline: pipeline)
        }

        window.orderOut(nil)
        return summary()
    }

    // MARK: 10,000 items

    private func largeTest(largeRoot: URL, settings: AppSettings, grid: GridViewController, pipeline: ThumbnailPipeline) async {
        let count = 10_000
        let generateStart = CACurrentMediaTime()
        do {
            try await Task.detached { try Fixtures.makeLargeFixture(at: largeRoot, count: count, folders: 200) }.value
        } catch {
            check("6 10,000-image fixture generated", false, error.localizedDescription)
            return
        }
        note(String(format: "10,000-image fixture written in %.1f s", CACurrentMediaTime() - generateStart))
        let before = await Task.detached { Fixtures.snapshot(of: largeRoot) }.value

        let scanStart = CACurrentMediaTime()
        let scanned = await Task.detached { FolderScanner.scan(root: largeRoot) }.value
        let scanTime = CACurrentMediaTime() - scanStart
        let sortStart = CACurrentMediaTime()
        let sorted = await Task.detached { LibraryQuery(sort: .name).apply(to: scanned) }.value
        let sortTime = CACurrentMediaTime() - sortStart

        settings.sortMode = .folder
        let favorites = FavoritesStore(fileURL: AppPaths.supportDirectory.appendingPathComponent("favorites-large.json"))
        let model = LibraryModel(settings: settings, favorites: favorites, rootsFile: nil)
        model.addFolder(largeRoot)
        await model.rescan().value
        await settle(model)

        grid.layout.targetSide = 150
        grid.setItems(model.visible, selected: nil, resetScroll: true)
        await pause(300)
        let gridCount = grid.itemCount
        // Scroll to the very end: the last tile on screen must be item 9,999.
        let endY = max(0, grid.layout.contentHeight - grid.scrollView.contentView.bounds.height)
        grid.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: endY))
        grid.scrollView.reflectScrolledClipView(grid.scrollView.contentView)
        await pause(150)
        let lastShown = grid.visibleIndexRange.upperBound - 1
        note("grid rows: \(grid.layout.rows) × \(grid.layout.columns) columns; last tile on screen at the bottom is item index \(lastShown)")
        check("6 10,000 images scanned and in the grid",
              scanned.count == count && sorted.count == count && model.visible.count == count && gridCount == count
              && lastShown == count - 1 && grid.layout.rows * grid.layout.columns >= count,
              String(format: "scan %d files in %.2f s, sort %.0f ms, grid view holds %d items in %d folders",
                     scanned.count, scanTime, sortTime * 1000, gridCount, model.folderCount))

        struct Pass { let label: String; let side: CGFloat; let speed: CGFloat; let seconds: Double; let clearMemory: Bool }
        let passes = [
            Pass(label: "dense grid, cold cache, steady", side: 56, speed: 2400, seconds: 6, clearMemory: false),
            Pass(label: "dense grid, warm cache, steady", side: 56, speed: 2400, seconds: 4, clearMemory: false),
            Pass(label: "dense grid, warm cache, fast fling", side: 56, speed: 14_000, seconds: 4, clearMemory: false),
            Pass(label: "large tiles, cold cache, steady", side: 220, speed: 3200, seconds: 5, clearMemory: false),
            Pass(label: "large tiles, disk cache only, fast fling", side: 220, speed: 14_000, seconds: 4, clearMemory: true),
        ]
        var allSmooth = true
        var worstLine = ""
        for pass in passes {
            if pass.clearMemory { pipeline.clearMemory() }
            grid.setThumbSide(pass.side)
            grid.scrollView.contentView.setBoundsOrigin(.zero)
            grid.scrollView.reflectScrolledClipView(grid.scrollView.contentView)
            await pause(250)
            let cells = grid.layout.indexRange(in: grid.scrollView.contentView.bounds).count
            let probe = ScrollProbe(grid: grid, pointsPerSecond: pass.speed, seconds: pass.seconds)
            let stats = await probe.run()
            let line = stats.describe(label: pass.label, cells: cells)
            print("       " + line)
            fflush(stdout)
            if !stats.isSmooth { allSmooth = false; worstLine = line }
            await pause(200)
        }
        let pipelineStats = pipeline.stats
        note("thumbnail pipeline totals: \(pipelineStats.generated) generated, \(pipelineStats.diskHits) from disk cache, \(pipelineStats.cancelled) cancelled, \(pipelineStats.failed) failed")
        note(String(format: "resident memory after scrolling: %.0f MB", Self.residentMegabytes()))
        check("6 scroll frame stats at 10,000 items", allSmooth,
              allSmooth ? "every pass within budget (see lines above)" : "over budget: \(worstLine)")

        let after = await Task.detached { Fixtures.snapshot(of: largeRoot) }.value
        check("6 10,000 fixture files unchanged after scrolling and thumbnailing", before == after && before.count >= count,
              "\(before.count) entries compared by SHA-256, size, modification time, extended attributes")
    }

    static func residentMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    private func summary() -> Bool {
        let failed = results.filter { !$0.passed }
        print("")
        print("VERIFY SUMMARY: \(results.count - failed.count) passed, \(failed.count) failed, \(results.count) checks")
        for failure in failed { print("  FAILED: \(failure.name) — \(failure.detail)") }
        print(failed.isEmpty ? "RESULT: PASS" : "RESULT: FAIL")
        fflush(stdout)
        return failed.isEmpty
    }
}

// MARK: - Scroll measurement

struct FrameStats {
    var usedDisplayLink = false
    var nominal: Double = 1.0 / 60.0
    var intervals: [Double] = []
    var work: [Double] = []
    var duration: Double = 0

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.down)))]
    }

    var longFrames: Int { intervals.filter { $0 > nominal * 1.5 }.count }

    /// Smooth = main-thread work per frame fits the display's frame budget at the 95th percentile,
    /// and (when a display link ran) fewer than 2% of frames arrived late.
    var isSmooth: Bool {
        guard !work.isEmpty else { return false }
        let workOK = percentile(work, 0.95) <= nominal
        guard usedDisplayLink, !intervals.isEmpty else { return workOK }
        return workOK && Double(longFrames) / Double(intervals.count) <= 0.02
    }

    func describe(label: String, cells: Int) -> String {
        let ms = 1000.0
        var text = String(format: "%@ [%d cells on screen]: %d frames in %.1f s", label, cells, work.count, duration)
        if usedDisplayLink, !intervals.isEmpty {
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            text += String(format: " = %.1f fps (display %.0f Hz); frame interval p50 %.1f / p95 %.1f / p99 %.1f / max %.1f ms; late frames %d (%.1f%%)",
                           1 / mean, 1 / nominal, percentile(intervals, 0.5) * ms, percentile(intervals, 0.95) * ms,
                           percentile(intervals, 0.99) * ms, (intervals.max() ?? 0) * ms,
                           longFrames, 100 * Double(longFrames) / Double(intervals.count))
        } else {
            text += " (no display link — display asleep or locked; timer-driven)"
        }
        text += String(format: "; main-thread work p50 %.2f / p95 %.2f / max %.2f ms",
                       percentile(work, 0.5) * ms, percentile(work, 0.95) * ms, (work.max() ?? 0) * ms)
        return text
    }
}

/// Scrolls the grid at a fixed speed, driven by the display's refresh, and records frame timing.
@MainActor
final class ScrollProbe: NSObject {
    private let grid: GridViewController
    private let speed: CGFloat
    private let seconds: Double
    private var stats = FrameStats()
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var lastTick: CFTimeInterval?
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    init(grid: GridViewController, pointsPerSecond: CGFloat, seconds: Double) {
        self.grid = grid
        self.speed = pointsPerSecond
        self.seconds = seconds
    }

    func run() async -> FrameStats {
        start = CACurrentMediaTime()
        let displayLink = grid.view.displayLink(target: self, selector: #selector(tick(_:)))
        displayLink.add(to: .main, forMode: .common)
        link = displayLink

        // If the display is asleep the link never fires; fall back to a timer after a short wait.
        try? await Task.sleep(nanoseconds: 700_000_000)
        if stats.work.isEmpty {
            displayLink.invalidate()
            link = nil
            start = CACurrentMediaTime()
            stats.usedDisplayLink = false
            while CACurrentMediaTime() - start < seconds {
                step(at: CACurrentMediaTime())
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
            stats.duration = CACurrentMediaTime() - start
            return stats
        }
        stats.usedDisplayLink = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if finished { continuation.resume() } else { self.continuation = continuation }
        }
        return stats
    }

    @objc private func tick(_ sender: CADisplayLink) {
        guard !finished else { return }
        let now = CACurrentMediaTime()
        let frame = sender.targetTimestamp - sender.timestamp
        if frame > 0 { stats.nominal = frame }
        if let lastTick { stats.intervals.append(now - lastTick) }
        lastTick = now
        if now - start >= seconds {
            finished = true
            stats.duration = now - start
            sender.invalidate()
            link = nil
            continuation?.resume()
            continuation = nil
            return
        }
        step(at: now)
    }

    private func step(at now: CFTimeInterval) {
        let scrollView = grid.scrollView
        let clip = scrollView.contentView
        let maxY = max(1, grid.layout.contentHeight - clip.bounds.height)
        // Triangle wave: down to the end, back up, and so on.
        let travelled = speed * CGFloat(now - start)
        let phase = travelled.truncatingRemainder(dividingBy: maxY * 2)
        let y = phase <= maxY ? phase : maxY * 2 - phase
        let began = CACurrentMediaTime()
        clip.setBoundsOrigin(NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
        grid.updateVisibleTiles()
        CATransaction.flush()
        stats.work.append(CACurrentMediaTime() - began)
    }
}
