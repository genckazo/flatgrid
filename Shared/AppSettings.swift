import Foundation
import Combine

/// User preferences, stored in the app's own defaults domain.
final class AppSettings: ObservableObject {
    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "Match System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    static let minThumbnailSize: Double = 28
    static let maxThumbnailSize: Double = 560

    private let defaults: UserDefaults

    @Published var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    @Published var uiSounds: Bool { didSet { defaults.set(uiSounds, forKey: "uiSounds") } }
    @Published var hoverSound: Bool { didSet { defaults.set(hoverSound, forKey: "hoverSound") } }
    @Published var slideTransition: Bool { didSet { defaults.set(slideTransition, forKey: "slideTransition") } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    @Published var videoAutoplay: Bool { didSet { defaults.set(videoAutoplay, forKey: "videoAutoplay") } }
    @Published var videoMuted: Bool { didSet { defaults.set(videoMuted, forKey: "videoMuted") } }
    @Published var cropThumbnails: Bool { didSet { defaults.set(cropThumbnails, forKey: "cropThumbnails") } }
    @Published var thumbnailSize: Double { didSet { defaults.set(thumbnailSize, forKey: "thumbnailSize") } }
    @Published var columnsOnPhone: Int { didSet { defaults.set(columnsOnPhone, forKey: "columnsOnPhone") } }
    @Published var sortMode: SortMode { didSet { defaults.set(sortMode.rawValue, forKey: "sortMode") } }
    @Published var visibleGroups: Set<MediaGroup> {
        didSet { defaults.set(visibleGroups.map(\.rawValue).sorted(), forKey: "visibleGroups") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        uiSounds = defaults.object(forKey: "uiSounds") as? Bool ?? true
        hoverSound = defaults.object(forKey: "hoverSound") as? Bool ?? true
        slideTransition = defaults.object(forKey: "slideTransition") as? Bool ?? true
        haptics = defaults.object(forKey: "haptics") as? Bool ?? true
        videoAutoplay = defaults.object(forKey: "videoAutoplay") as? Bool ?? true
        videoMuted = defaults.object(forKey: "videoMuted") as? Bool ?? false
        cropThumbnails = defaults.object(forKey: "cropThumbnails") as? Bool ?? false
        let size = defaults.object(forKey: "thumbnailSize") as? Double ?? 150
        thumbnailSize = min(max(size, Self.minThumbnailSize), Self.maxThumbnailSize)
        let columns = defaults.object(forKey: "columnsOnPhone") as? Int ?? 4
        columnsOnPhone = min(max(columns, 1), 12)
        sortMode = SortMode(rawValue: defaults.integer(forKey: "sortMode")) ?? .name
        if let stored = defaults.stringArray(forKey: "visibleGroups") {
            visibleGroups = Set(stored.compactMap(MediaGroup.init(rawValue:)))
        } else {
            visibleGroups = Set(MediaGroup.allCases.filter(\.visibleByDefault))
        }
    }

    func isVisible(_ group: MediaGroup) -> Bool { visibleGroups.contains(group) }

    func setVisible(_ group: MediaGroup, _ visible: Bool) {
        if visible { visibleGroups.insert(group) } else { visibleGroups.remove(group) }
    }
}
