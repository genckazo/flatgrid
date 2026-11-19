import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var settings: AppSettings
    @State private var cacheSize: Int64?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(AppSettings.Theme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Crop thumbnails to fill their tile", isOn: $settings.cropThumbnails)
            }

            Section("Feedback") {
                Toggle("Tick when the cursor moves across thumbnails", isOn: $settings.hoverSound)
                Toggle("Sounds for favorites and zoom", isOn: $settings.uiSounds)
                Toggle("Trackpad haptics", isOn: $settings.haptics)
            }

            Section("Video") {
                Toggle("Play videos automatically when opened", isOn: $settings.videoAutoplay)
                Toggle("Start muted", isOn: $settings.videoMuted)
            }

            Section("Viewer") {
                Toggle("Slide between items", isOn: $settings.slideTransition)
            }

            Section {
                ForEach(MediaGroup.allCases) { group in
                    Toggle(isOn: Binding(
                        get: { settings.isVisible(group) },
                        set: { settings.setVisible(group, $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(group.title)  ·  \((model.groupCounts[group] ?? 0).formatted())")
                            Text(extensions(for: group))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text("File types shown in the grid")
            } footer: {
                Text("Layered documents are off until you turn them on.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Thumbnail cache") {
                    HStack(spacing: 10) {
                        Text(cacheSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            ThumbnailPipeline.shared.clearCache()
                            refreshCacheSize()
                        }
                    }
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("FlatGrid only reads your files. Its own settings, favorites and thumbnail cache stay inside the app's container, and it makes no network connections.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 640)
        .onAppear(perform: refreshCacheSize)
    }

    private func extensions(for group: MediaGroup) -> String {
        let set: Set<String>
        switch group {
        case .image: set = MediaTypes.imageExtensions
        case .video: set = MediaTypes.videoExtensions
        case .raw: set = MediaTypes.rawExtensions
        case .layered: set = MediaTypes.layeredExtensions
        }
        return set.sorted().joined(separator: " ")
    }

    private func refreshCacheSize() {
        cacheSize = nil
        DispatchQueue.global(qos: .utility).async {
            let size = ThumbnailPipeline.shared.diskCacheSize()
            DispatchQueue.main.async { cacheSize = size }
        }
    }
}

struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private let rows: [(String, String)] = [
        ("← →", "Previous / next item"),
        ("↑ ↓", "Move between rows in the grid"),
        ("⌘↑ ⌘↓", "Previous / next folder"),
        ("Space", "Open or close the selected item"),
        ("Tab", "Show or hide the interface"),
        ("+ −", "Thumbnail size"),
        ("1 – 6", "Sort: date created, date added, name, type, folders, random"),
        ("S", "Search"),
        ("F", "Add or remove favorite"),
        ("Z", "Original size (100%)"),
        ("R", "Reveal in Finder"),
        ("I", "Get info"),
        ("C", "Copy"),
        ("[ ]", "Rotate left / right (view only)"),
        ("⌘,", "Settings"),
        ("Esc", "Close viewer, clear search"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard Shortcuts").font(.system(size: 16, weight: .semibold, design: .rounded))
            VStack(alignment: .leading, spacing: 7) {
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(row.0)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 72, alignment: .trailing)
                            .foregroundStyle(Theme.accent)
                        Text(row.1).font(.system(size: 12))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 470)
    }
}
