import AppKit
import SwiftUI

struct TopBar: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var settings: AppSettings
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 70)

            foldersMenu

            searchField
                .frame(minWidth: 150, idealWidth: 260, maxWidth: 320)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                ForEach(MediaGroup.allCases) { group in
                    TypeChip(group: group, count: model.groupCounts[group] ?? 0, isOn: settings.isVisible(group)) {
                        settings.setVisible(group, !settings.isVisible(group))
                    }
                }
            }

            BarButton(symbol: model.favoritesOnly ? "heart.fill" : "heart", isOn: model.favoritesOnly, help: "Show favorites only") {
                model.favoritesOnly.toggle()
            }

            sortMenu

            HStack(spacing: 5) {
                Image(systemName: "square.grid.4x3.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                Slider(value: sizeBinding, in: log(AppSettings.minThumbnailSize)...log(AppSettings.maxThumbnailSize))
                    .controlSize(.mini)
                    .frame(width: 96)
                    .help("Thumbnail size (+ / −)")
                Image(systemName: "square.fill").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.trailing, 12)
        .frame(height: 46)
        .background(WindowDragArea())
        .background(Theme.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
    }

    private var sizeBinding: Binding<Double> {
        Binding(get: { log(settings.thumbnailSize) }, set: { settings.thumbnailSize = exp($0) })
    }

    /// A plus button, then one chip per added folder with its item count.
    private var foldersMenu: some View {
        HStack(spacing: 6) {
            BarButton(symbol: "plus", help: "Add a folder (⌘O)") { AppServices.shared.chooseFolders() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.roots) { root in folderChip(root) }
                }
            }
            .frame(maxWidth: 340)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func folderChip(_ root: LibraryModel.Root) -> some View {
        let missing = model.unavailableRoots.contains(root.id)
        return Menu {
            Button("Reveal in Finder") {
                if let url = model.url(for: root) { AppServices.shared.reveal(url) }
            }
            Button("Rescan") { model.rescan([root]) }
            Divider()
            Button("Remove from FlatGrid") { model.removeRoot(root.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: missing ? "externaldrive.badge.xmark" : "folder")
                // One Text: a borderless menu label only shows its first text.
                Text(root.name) + Text("   " + (missing ? "offline" : (model.rootCounts[root.id] ?? 0).formatted()))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
        .help(missing ? "\(root.name) is not connected" : root.path)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField("Name, tag or metadata", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { AppServices.shared.focusGrid() }
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(searchFocused ? Theme.accent.opacity(0.8) : .clear, lineWidth: 1.5))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SortMode.allCases) { mode in
                Button {
                    model.setSort(mode)
                } label: {
                    if settings.sortMode == mode {
                        Label("\(mode.rawValue)   \(mode.title)", systemImage: "checkmark")
                    } else {
                        Text("\(mode.rawValue)   \(mode.title)")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                Text(settings.sortMode.title).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
        .help("Sort order (keys 1–6)")
    }
}

struct TypeChip: View {
    let group: MediaGroup
    let count: Int
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(group.shortTitle)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .background(isOn ? Theme.accent : Theme.field, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("\(group.title): \(count.formatted()) in library — \(isOn ? "shown" : "hidden")")
    }
}

struct BarButton: View {
    let symbol: String
    var isOn = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(isOn ? Theme.accent : Color.primary)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct StatusBar: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            if model.isScanning {
                ProgressView().controlSize(.mini)
                Text("Scanning… \(model.scanProgress.formatted())")
            } else {
                Text("\(model.visible.count.formatted()) items · \(model.folderCount.formatted()) folders")
                if model.visible.count != model.allItems.count {
                    Text("of \(model.allItems.count.formatted())").foregroundStyle(.tertiary)
                }
                if model.isIndexingMetadata {
                    Text("· reading metadata for search").foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            if let item = model.currentItem {
                Text(item.folderName).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                Text(item.name).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Theme.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
