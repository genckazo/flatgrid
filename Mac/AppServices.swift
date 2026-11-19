import AppKit
import Combine
import UniformTypeIdentifiers

/// Objects that live for the whole run of the app.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let settings: AppSettings
    let favorites: FavoritesStore
    let model: LibraryModel
    let keys = KeyHandler()
    weak var window: NSWindow?
    weak var grid: GridViewController?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        settings = Preview.isActive ? AppSettings(defaults: Preview.makeDefaults()) : AppSettings()
        favorites = FavoritesStore(fileURL: AppPaths.favoritesFile)
        model = LibraryModel(settings: settings, favorites: favorites, rootsFile: AppPaths.rootsFile)
        keys.services = self
    }

    func start() {
        applyTheme(settings.theme)
        settings.$theme.dropFirst().sink { [weak self] theme in
            DispatchQueue.main.async { self?.applyTheme(theme) }
        }.store(in: &cancellables)
        model.$interfaceHidden.dropFirst().sink { [weak self] hidden in
            DispatchQueue.main.async { self?.setWindowButtons(hidden: hidden) }
        }.store(in: &cancellables)
        keys.install()
        if Preview.isActive {
            Preview.start(services: self)
        } else {
            model.loadPersistedRoots()
        }
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
    }

    private func applyTheme(_ theme: AppSettings.Theme) {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func setWindowButtons(hidden: Bool) {
        guard let window else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = hidden
        }
    }

    // MARK: Actions on files (all read-only)

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose folders to browse. Files stay where they are."
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls { self.model.addFolder(url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    func reveal(_ item: MediaItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copy(_ item: MediaItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item.url as NSURL])
        model.flash("Copied \(item.name)")
    }

    func toggleFavorite(_ item: MediaItem) {
        let nowFavorite = model.toggleFavorite(item)
        Feedback.play(.favorite, settings: settings)
        if settings.uiSounds { Sounds.shared.play(nowFavorite ? .favoriteOn : .favoriteOff) }
        model.flash(nowFavorite ? "Added to favorites" : "Removed from favorites")
    }

    func focusGrid() {
        guard let window, let grid else { return }
        window.makeFirstResponder(grid.documentView)
    }

    func contextMenu(for index: Int) -> NSMenu? {
        guard model.visible.indices.contains(index) else { return nil }
        let item = model.visible[index]
        model.selectedIndex = index
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let entry = ClosureMenuItem(title: title, handler: action)
            menu.addItem(entry)
        }
        add("Open") { [weak self] in self?.model.open(index) }
        add(model.isFavorite(item) ? "Remove from Favorites" : "Add to Favorites") { [weak self] in self?.toggleFavorite(item) }
        menu.addItem(.separator())
        add("Reveal in Finder") { [weak self] in self?.reveal(item) }
        add("Copy") { [weak self] in self?.copy(item) }
        add("Get Info") { [weak self] in self?.model.showInfo = true }
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

// MARK: - Haptics (sounds live in Sounds.swift)

enum Feedback {
    enum Event { case move, edge, open, close, favorite, toggle }

    @MainActor
    static func play(_ event: Event, settings: AppSettings) {
        if settings.haptics {
            let pattern: NSHapticFeedbackManager.FeedbackPattern
            switch event {
            case .move, .toggle: pattern = .alignment
            case .edge: pattern = .levelChange
            case .open, .close, .favorite: pattern = .generic
            }
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
    }
}
