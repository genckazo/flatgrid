import SwiftUI
import UIKit
import AudioToolbox

@main
struct FlatGridMobileApp: App {
    @StateObject private var services = MobileServices()

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(services)
                .environmentObject(services.model)
                .environmentObject(services.settings)
        }
    }
}

/// Objects that live for the whole run of the iPhone app.
@MainActor
final class MobileServices: ObservableObject {
    let settings: AppSettings
    let favorites: FavoritesStore
    let model: LibraryModel
    @Published var isBuildingSamples = false

    static let sampleFolderName = "FlatGrid Samples"

    init() {
        settings = AppSettings()
        favorites = FavoritesStore(fileURL: AppPaths.favoritesFile)
        model = LibraryModel(settings: settings, favorites: favorites, rootsFile: AppPaths.rootsFile)
        model.loadPersistedRoots()
        if CommandLine.arguments.contains("--preview"), model.roots.isEmpty {
            loadSamples()
        }
    }

    var sampleFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.sampleFolderName, isDirectory: true)
    }

    /// Generates a small sample library inside the app's own Documents folder and opens it.
    func loadSamples() {
        guard !isBuildingSamples else { return }
        isBuildingSamples = true
        let folder = sampleFolder
        Task {
            if !FileManager.default.fileExists(atPath: folder.path) {
                do {
                    _ = try await Fixtures.makeSmallFixture(at: folder.appendingPathComponent("Mixed", isDirectory: true))
                    let bulk = folder.appendingPathComponent("Bulk", isDirectory: true)
                    try await Task.detached { try Fixtures.makeLargeFixture(at: bulk, count: 1200, folders: 12) }.value
                } catch {
                    model.flash("Could not create samples")
                }
            }
            model.addFolder(folder)
            isBuildingSamples = false
        }
    }

    func removeSamples() {
        if let root = model.roots.first(where: { $0.name == Self.sampleFolderName }) {
            model.removeRoot(root.id)
        }
        try? FileManager.default.removeItem(at: sampleFolder)
    }

    func toggleFavorite(_ item: MediaItem) {
        let nowFavorite = model.toggleFavorite(item)
        MobileFeedback.play(.confirm, settings: settings)
        model.flash(nowFavorite ? "Added to favorites" : "Removed from favorites")
    }

    func copy(_ item: MediaItem) {
        UIPasteboard.general.url = item.url
        model.flash("Copied \(item.name)")
    }
}

enum MobileFeedback {
    enum Event { case tick, confirm, edge }

    @MainActor
    static func play(_ event: Event, settings: AppSettings) {
        if settings.haptics {
            switch event {
            case .tick: UISelectionFeedbackGenerator().selectionChanged()
            case .confirm: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .edge: UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
        if settings.uiSounds {
            switch event {
            case .tick: AudioServicesPlaySystemSound(1104)
            case .confirm: AudioServicesPlaySystemSound(1105)
            case .edge: AudioServicesPlaySystemSound(1053)
            }
        }
    }
}

enum MobileTheme {
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.21)
    static let uiAccent = UIColor(red: 1.0, green: 0.42, blue: 0.21, alpha: 1)
}
