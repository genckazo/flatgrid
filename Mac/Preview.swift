import AppKit

/// `FlatGrid --preview`: opens the normal app on a generated sample library kept in the app's own
/// temporary directory, with separate settings. A development aid for looking at the interface
/// without pointing the app at real folders.
enum Preview {
    static var isActive: Bool { CommandLine.arguments.contains("--preview") }

    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FlatGridPreview", isDirectory: true)
    }

    private static func value(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func prepare() {
        try? FileManager.default.removeItem(at: root)
        AppPaths.overrideBase = root.appendingPathComponent("AppData", isDirectory: true)
    }

    static func makeDefaults() -> UserDefaults {
        let name = "flatgrid.preview"
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name) ?? .standard
    }

    @MainActor
    static func start(services: AppServices) {
        let model = services.model
        let settings = services.settings
        if let theme = value(after: "--preview-theme").flatMap(AppSettings.Theme.init(rawValue:)) {
            settings.theme = theme
        }
        if let size = value(after: "--preview-size").flatMap(Double.init) {
            settings.thumbnailSize = size
        }
        if CommandLine.arguments.contains("--preview-all-types") {
            settings.visibleGroups = Set(MediaGroup.allCases)
        }
        Task { @MainActor in
            let library = root.appendingPathComponent("Library", isDirectory: true)
            do {
                _ = try await Fixtures.makeSmallFixture(at: library.appendingPathComponent("Samples", isDirectory: true))
                let bulk = library.appendingPathComponent("Bulk", isDirectory: true)
                try await Task.detached { try Fixtures.makeLargeFixture(at: bulk, count: 1500, folders: 12) }.value
            } catch {
                print("preview fixture failed: \(error.localizedDescription)")
            }
            if !CommandLine.arguments.contains("--preview-empty") {
                model.addFolder(library)
                await model.rescan().value
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            await model.settle()
            for index in [1, 4, 9] where model.visible.indices.contains(index) {
                model.toggleFavorite(model.visible[index])
            }
            if let query = value(after: "--preview-search") { model.searchText = query }
            if let index = value(after: "--preview-open").flatMap(Int.init) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                model.open(index)
            } else if let index = value(after: "--preview-select").flatMap(Int.init) {
                model.selectedIndex = index
            }
            if CommandLine.arguments.contains("--preview-info") { model.showInfo = true }
            if CommandLine.arguments.contains("--preview-settings") {
                (NSApp.delegate as? AppDelegate)?.showSettings(nil)
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            print("PREVIEW READY items=\(model.visible.count) windows=\(NSApp.windows.count) attached=\(services.window != nil)")
            for window in NSApp.windows {
                print("WINDOW \(window.windowNumber) \(window.title.isEmpty ? "untitled" : window.title.replacingOccurrences(of: " ", with: "_")) \(Int(window.frame.width))x\(Int(window.frame.height)) visible=\(window.isVisible)")
            }
            fflush(stdout)
            if CommandLine.arguments.contains("--preview-snapshot") {
                for window in NSApp.windows where window.isVisible {
                    guard let view = window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        print("SNAPSHOT \(window.title.replacingOccurrences(of: " ", with: "_")) \(png.base64EncodedString())")
                    }
                }
                fflush(stdout)
                exit(0)
            }
        }
    }
}
