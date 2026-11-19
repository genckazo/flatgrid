import Foundation

/// The six sort orders, bound to keys 1–6.
enum SortMode: Int, CaseIterable, Codable, Identifiable, Sendable {
    case dateCreated = 1
    case dateAdded = 2
    case name = 3
    case type = 4
    case folder = 5
    case random = 6

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .dateCreated: return "Date created"
        case .dateAdded: return "Date added"
        case .name: return "Name"
        case .type: return "Type"
        case .folder: return "Folders"
        case .random: return "Random"
        }
    }

    var symbol: String {
        switch self {
        case .dateCreated: return "calendar"
        case .dateAdded: return "calendar.badge.plus"
        case .name: return "textformat.abc"
        case .type: return "doc"
        case .folder: return "folder"
        case .random: return "shuffle"
        }
    }
}

/// Small deterministic generator so a shuffle can be reproduced from its seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Pure description of what the grid should show. No side effects, safe off the main thread.
struct LibraryQuery: Sendable {
    var visibleGroups: Set<MediaGroup> = Set(MediaGroup.allCases.filter(\.visibleByDefault))
    var favoritesOnly = false
    var favoritePaths: Set<String> = []
    var searchText = ""
    var sort: SortMode = .name
    var randomSeed: UInt64 = 1

    func apply(to items: [MediaItem], metadata: [String: String] = [:]) -> [MediaItem] {
        let tokens = foldForSearch(searchText)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)

        var result: [MediaItem] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard visibleGroups.contains(item.group) else { continue }
            if favoritesOnly && !favoritePaths.contains(item.path) { continue }
            if !tokens.isEmpty {
                let extra = metadata[item.path]
                var matchesAll = true
                for token in tokens {
                    if item.searchKey.contains(token) { continue }
                    if let extra, extra.contains(token) { continue }
                    matchesAll = false
                    break
                }
                if !matchesAll { continue }
            }
            result.append(item)
        }
        return LibraryQuery.sorted(result, by: sort, seed: randomSeed)
    }

    static func sorted(_ items: [MediaItem], by mode: SortMode, seed: UInt64) -> [MediaItem] {
        switch mode {
        case .dateCreated:
            return items.sorted { a, b in
                a.created != b.created ? a.created > b.created : nameOrder(a, b)
            }
        case .dateAdded:
            return items.sorted { a, b in
                a.added != b.added ? a.added > b.added : nameOrder(a, b)
            }
        case .name:
            return items.sorted(by: nameOrder)
        case .type:
            return items.sorted { a, b in
                let left = a.fileExtension, right = b.fileExtension
                return left != right ? left < right : nameOrder(a, b)
            }
        case .folder:
            return items.sorted { a, b in
                if a.folderPath != b.folderPath {
                    let order = a.folderPath.localizedStandardCompare(b.folderPath)
                    if order != .orderedSame { return order == .orderedAscending }
                    return a.folderPath < b.folderPath
                }
                return nameOrder(a, b)
            }
        case .random:
            // Shuffle a stable base order so the same seed always gives the same result.
            var base = items.sorted { $0.path < $1.path }
            var generator = SplitMix64(seed: seed)
            base.shuffle(using: &generator)
            return base
        }
    }

    /// Finder-style ordering ("img2" before "img10"), with the path as a tie-breaker.
    private static func nameOrder(_ a: MediaItem, _ b: MediaItem) -> Bool {
        let order = a.name.localizedStandardCompare(b.name)
        if order != .orderedSame { return order == .orderedAscending }
        return a.path < b.path
    }
}
