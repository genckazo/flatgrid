import Foundation
import Combine

/// The library: which folders are added, what was found in them, and what the grid shows.
@MainActor
final class LibraryModel: ObservableObject {
    struct Root: Identifiable, Codable, Hashable {
        var id: UUID
        var bookmark: Data
        var path: String
        var name: String
    }

    let settings: AppSettings
    let favorites: FavoritesStore
    private let rootsFile: URL?

    @Published private(set) var roots: [Root] = []
    @Published private(set) var rootCounts: [UUID: Int] = [:]
    @Published private(set) var unavailableRoots: Set<UUID> = []
    @Published private(set) var allItems: [MediaItem] = []
    @Published private(set) var visible: [MediaItem] = []
    @Published private(set) var visibleVersion = 0
    @Published private(set) var favoritesVersion = 0
    @Published private(set) var groupCounts: [MediaGroup: Int] = [:]
    @Published private(set) var folderCount = 0
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress = 0
    @Published private(set) var isIndexingMetadata = false
    @Published private(set) var rotations: [String: Int] = [:]
    @Published private(set) var randomSeed: UInt64 = UInt64.random(in: 1...UInt64.max)

    @Published var searchText = "" { didSet { if searchText != oldValue { recompute() } } }
    @Published var favoritesOnly = false { didSet { if favoritesOnly != oldValue { recompute() } } }
    @Published var selectedIndex: Int?
    @Published var viewerIndex: Int?
    @Published var showInfo = false
    @Published var interfaceHidden = false
    @Published var actualSize = false
    @Published var showShortcuts = false
    /// Direction of the last step in the viewer, for the slide transition.
    @Published private(set) var movedForward = true
    /// Bumped to ask the UI to put the cursor in the search field.
    @Published var searchFocusRequest = 0
    /// Short confirmation shown briefly over the content ("Copied", "Added to favorites").
    @Published private(set) var notice: String?
    private var noticeSerial = 0

    func flash(_ text: String) {
        noticeSerial += 1
        let serial = noticeSerial
        notice = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard let self, self.noticeSerial == serial else { return }
            self.notice = nil
        }
    }

    private var rootURLs: [UUID: URL] = [:]
    private var scopedURLs: [UUID: URL] = [:]
    private var itemsByRoot: [UUID: [MediaItem]] = [:]
    private var metadataIndex: [String: String] = [:]
    private var metadataStamp: [String: String] = [:]
    private var metadataTask: Task<Void, Never>?
    private var recomputeTask: Task<Void, Never>?
    private var generation = 0
    private var activeScans = 0
    private var cancellables: Set<AnyCancellable> = []

    init(settings: AppSettings, favorites: FavoritesStore, rootsFile: URL?) {
        self.settings = settings
        self.favorites = favorites
        self.rootsFile = rootsFile
        // @Published fires before the value is stored, so hop a turn before reading it.
        settings.$visibleGroups.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.recompute() }
        }.store(in: &cancellables)
        settings.$sortMode.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.recompute() }
        }.store(in: &cancellables)
    }

    // MARK: Roots

    private static var bookmarkCreation: URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        #else
        return []
        #endif
    }

    private static var bookmarkResolution: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return [.withSecurityScope, .withoutUI]
        #else
        return [.withoutUI]
        #endif
    }

    func loadPersistedRoots() {
        guard let rootsFile, let data = try? Data(contentsOf: rootsFile),
              var stored = try? JSONDecoder().decode([Root].self, from: data) else { return }
        var refreshed = false
        for index in stored.indices {
            let root = stored[index]
            var stale = false
            if !root.bookmark.isEmpty,
               let url = try? URL(resolvingBookmarkData: root.bookmark, options: Self.bookmarkResolution,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                if url.startAccessingSecurityScopedResource() { scopedURLs[root.id] = url }
                rootURLs[root.id] = url
                if stale, let fresh = try? url.bookmarkData(options: Self.bookmarkCreation,
                                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
                    stored[index].bookmark = fresh
                    refreshed = true
                }
                if url.path != root.path {
                    stored[index].path = url.path
                    stored[index].name = url.lastPathComponent
                    refreshed = true
                }
            } else {
                // Drive not connected, or the bookmark cannot be resolved right now. Keep the entry.
                rootURLs[root.id] = URL(fileURLWithPath: root.path, isDirectory: true)
            }
        }
        roots = stored
        if refreshed { saveRoots() }
        rescan()
    }

    /// Adds a folder as a new root. Returns false when it is already there.
    @discardableResult
    func addFolder(_ url: URL) -> Bool {
        let folder = url.standardizedFileURL
        guard !roots.contains(where: { $0.path == folder.path }) else { return false }
        let scoped = folder.startAccessingSecurityScopedResource()
        var bookmark = try? folder.bookmarkData(options: Self.bookmarkCreation,
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
        if bookmark == nil {
            bookmark = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        let root = Root(id: UUID(), bookmark: bookmark ?? Data(), path: folder.path, name: folder.lastPathComponent)
        if scoped { scopedURLs[root.id] = folder }
        rootURLs[root.id] = folder
        roots.append(root)
        saveRoots()
        rescan([root])
        return true
    }

    func removeRoot(_ id: UUID) {
        roots.removeAll { $0.id == id }
        scopedURLs[id]?.stopAccessingSecurityScopedResource()
        scopedURLs[id] = nil
        rootURLs[id] = nil
        itemsByRoot[id] = nil
        rootCounts[id] = nil
        unavailableRoots.remove(id)
        saveRoots()
        rebuildAllItems()
    }

    func url(for root: Root) -> URL? { rootURLs[root.id] }

    private func saveRoots() {
        guard let rootsFile, let data = try? JSONEncoder().encode(roots) else { return }
        try? data.write(to: rootsFile, options: .atomic)
    }

    // MARK: Scanning

    @discardableResult
    func rescan(_ subset: [Root]? = nil) -> Task<Void, Never> {
        let targets: [(UUID, URL)] = (subset ?? roots).compactMap { root in
            rootURLs[root.id].map { (root.id, $0) }
        }
        activeScans += 1
        isScanning = true
        scanProgress = 0
        return Task { [weak self] in
            for (id, url) in targets {
                let outcome = await Task.detached(priority: .userInitiated) { [weak self] () -> (Bool, [MediaItem]) in
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    guard exists, isDirectory.boolValue else { return (false, []) }
                    let found = FolderScanner.scan(root: url, progress: { count in
                        Task { @MainActor [weak self] in self?.scanProgress = count }
                    })
                    return (true, found)
                }.value
                guard let self else { return }
                guard self.roots.contains(where: { $0.id == id }) else { continue }
                self.itemsByRoot[id] = outcome.1
                self.rootCounts[id] = outcome.1.count
                if outcome.0 { self.unavailableRoots.remove(id) } else { self.unavailableRoots.insert(id) }
            }
            guard let self else { return }
            self.activeScans -= 1
            if self.activeScans == 0 { self.isScanning = false }
            await self.rebuildAllItems().value
        }
    }

    @discardableResult
    private func rebuildAllItems() -> Task<Void, Never> {
        var seen = Set<String>()
        var merged: [MediaItem] = []
        for root in roots {
            for item in itemsByRoot[root.id] ?? [] where seen.insert(item.path).inserted {
                merged.append(item)
            }
        }
        allItems = merged
        var counts: [MediaGroup: Int] = [:]
        for item in merged { counts[item.group, default: 0] += 1 }
        groupCounts = counts
        if favorites.reconcile(knownPaths: seen) { favoritesVersion += 1 }
        startMetadataIndexing()
        return recompute()
    }

    // MARK: Query

    var currentQuery: LibraryQuery {
        LibraryQuery(
            visibleGroups: settings.visibleGroups,
            favoritesOnly: favoritesOnly,
            favoritePaths: favoritesOnly ? favorites.paths : [],
            searchText: searchText,
            sort: settings.sortMode,
            randomSeed: randomSeed
        )
    }

    @discardableResult
    func recompute() -> Task<Void, Never> {
        generation += 1
        let myGeneration = generation
        let query = currentQuery
        let items = allItems
        let metadata = query.searchText.isEmpty ? [:] : metadataIndex
        let selectedPath = selectedIndex.flatMap { visible.indices.contains($0) ? visible[$0].path : nil }
        let viewerPath = viewerIndex.flatMap { visible.indices.contains($0) ? visible[$0].path : nil }
        let task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                query.apply(to: items, metadata: metadata)
            }.value
            guard let self, myGeneration == self.generation else { return }
            self.publish(result, selectedPath: selectedPath, viewerPath: viewerPath)
        }
        recomputeTask = task
        return task
    }

    private func publish(_ result: [MediaItem], selectedPath: String?, viewerPath: String?) {
        let oldViewerIndex = viewerIndex
        visible = result
        var folders = Set<String>()
        for item in result { folders.insert(item.folderPath) }
        folderCount = folders.count

        var newSelection: Int?
        var newViewer: Int?
        if selectedPath != nil || viewerPath != nil {
            for (index, item) in result.enumerated() {
                if item.path == selectedPath { newSelection = index }
                if item.path == viewerPath { newViewer = index }
            }
        }
        if oldViewerIndex != nil {
            if let newViewer {
                viewerIndex = newViewer
            } else if result.isEmpty {
                viewerIndex = nil
            } else {
                viewerIndex = min(oldViewerIndex ?? 0, result.count - 1)
            }
            selectedIndex = viewerIndex
        } else {
            selectedIndex = newSelection
        }
        visibleVersion += 1
    }

    func setSort(_ mode: SortMode) {
        if mode == .random { randomSeed = UInt64.random(in: 1...UInt64.max) }
        if settings.sortMode == mode {
            if mode == .random { recompute() }
        } else {
            settings.sortMode = mode
        }
    }

    // MARK: Metadata index (search only)

    private func startMetadataIndexing() {
        metadataTask?.cancel()
        let pending = allItems.filter { metadataStamp[$0.path] != $0.cacheKey }
        guard !pending.isEmpty else { isIndexingMetadata = false; return }
        isIndexingMetadata = true
        metadataTask = Task.detached(priority: .utility) { [weak self] in
            var batch: [(String, String, String)] = []
            for item in pending {
                if Task.isCancelled { return }
                batch.append((item.path, item.cacheKey, MetadataReader.searchText(for: item)))
                if batch.count >= 500 {
                    let chunk = batch
                    batch = []
                    await self?.mergeMetadata(chunk, final: false)
                }
            }
            if Task.isCancelled { return }
            await self?.mergeMetadata(batch, final: true)
        }
    }

    private func mergeMetadata(_ chunk: [(String, String, String)], final: Bool) {
        for (path, stamp, text) in chunk {
            metadataStamp[path] = stamp
            if text.isEmpty { metadataIndex[path] = nil } else { metadataIndex[path] = text }
        }
        if final {
            isIndexingMetadata = false
            if !searchText.isEmpty { recompute() }
        }
    }

    /// Waits until scanning-related background work has settled. Used by `--verify`.
    func settle() async {
        await metadataTask?.value
        await recomputeTask?.value
    }

    // MARK: Selection and viewer

    var currentIndex: Int? { viewerIndex ?? selectedIndex }

    var currentItem: MediaItem? {
        guard let index = currentIndex, visible.indices.contains(index) else { return nil }
        return visible[index]
    }

    func open(_ index: Int) {
        guard visible.indices.contains(index) else { return }
        selectedIndex = index
        actualSize = false
        viewerIndex = index
    }

    func closeViewer() {
        viewerIndex = nil
        actualSize = false
    }

    /// Moves the viewer (or the grid selection) by `delta` items. Returns true when it moved.
    @discardableResult
    func step(_ delta: Int) -> Bool {
        guard !visible.isEmpty else { return false }
        let from = currentIndex ?? (delta > 0 ? -1 : visible.count)
        let target = min(max(from + delta, 0), visible.count - 1)
        guard target != currentIndex else { return false }
        move(to: target)
        return true
    }

    func move(to index: Int) {
        guard visible.indices.contains(index) else { return }
        if let current = currentIndex, current != index { movedForward = index > current }
        selectedIndex = index
        if viewerIndex != nil {
            actualSize = false
            viewerIndex = index
        }
    }

    /// Index of the first item of the next folder, or of the current/previous folder going back.
    func folderJumpTarget(from index: Int, forward: Bool) -> Int? {
        guard visible.indices.contains(index) else { return nil }
        let folder = visible[index].folderPath
        if forward {
            var i = index + 1
            while i < visible.count {
                if visible[i].folderPath != folder { return i }
                i += 1
            }
            return nil
        }
        var start = index
        while start > 0, visible[start - 1].folderPath == folder { start -= 1 }
        if start < index { return start }
        guard start > 0 else { return nil }
        let previous = visible[start - 1].folderPath
        var i = start - 1
        while i > 0, visible[i - 1].folderPath == previous { i -= 1 }
        return i
    }

    @discardableResult
    func jumpFolder(forward: Bool) -> Bool {
        guard let index = currentIndex ?? (visible.isEmpty ? nil : 0),
              let target = folderJumpTarget(from: index, forward: forward) else { return false }
        move(to: target)
        return true
    }

    // MARK: Favorites and rotation

    func isFavorite(_ item: MediaItem) -> Bool { favorites.contains(item.path) }

    @discardableResult
    func toggleFavorite(_ item: MediaItem) -> Bool {
        let state = favorites.toggle(item)
        favoritesVersion += 1
        if favoritesOnly { recompute() }
        return state
    }

    func rotation(for item: MediaItem) -> Int { rotations[item.path] ?? 0 }

    /// View-only rotation in quarter turns. The file is never touched.
    func rotate(_ item: MediaItem, clockwise: Bool) {
        let turns = ((rotations[item.path] ?? 0) + (clockwise ? 1 : 3)) % 4
        rotations[item.path] = turns == 0 ? nil : turns
    }

    func adjustThumbnailSize(by factor: Double) {
        let next = settings.thumbnailSize * factor
        settings.thumbnailSize = min(max(next, AppSettings.minThumbnailSize), AppSettings.maxThumbnailSize)
    }
}
