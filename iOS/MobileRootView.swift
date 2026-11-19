import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MobileRootView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var services: MobileServices
    @State private var showPicker = false
    @State private var showSettings = false
    @State private var infoItem: MediaItem?
    @State private var shareItem: MediaItem?

    private var colorScheme: ColorScheme? {
        switch settings.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                if model.roots.isEmpty {
                    emptyState
                } else {
                    MobileGridView(
                        model: model, settings: settings, services: services,
                        onShare: { shareItem = $0 }, onInfo: { infoItem = $0 }
                    )
                    .ignoresSafeArea(edges: .bottom)
                    if model.visible.isEmpty { nothingToShow }
                }
                if let notice = model.notice, model.viewerIndex == nil {
                    VStack {
                        Spacer()
                        Text(notice)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 70)
                    }
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Name or metadata")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        }
        .tint(MobileTheme.accent)
        .preferredColorScheme(colorScheme)
        .sheet(isPresented: $showPicker) {
            FolderPicker { urls in
                for url in urls { model.addFolder(url) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showSettings) { MobileSettingsView(showPicker: $showPicker) }
        .sheet(item: $infoItem) { InfoSheet(item: $0) }
        .sheet(item: $shareItem) { ActivityView(url: $0.url) }
        .fullScreenCover(isPresented: Binding(
            get: { model.viewerIndex != nil },
            set: { if !$0 { model.closeViewer() } }
        )) {
            MobileViewer()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(services)
        }
        .animation(.easeOut(duration: 0.15), value: model.notice)
    }

    private var title: String {
        if model.roots.isEmpty { return "FlatGrid" }
        if model.isScanning { return "Scanning… \(model.scanProgress.formatted())" }
        return "\(model.visible.count.formatted()) items"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                ForEach(model.roots) { root in
                    Menu {
                        Button("Rescan", systemImage: "arrow.clockwise") { model.rescan([root]) }
                        Button("Remove from FlatGrid", systemImage: "minus.circle", role: .destructive) {
                            if root.name == MobileServices.sampleFolderName {
                                services.removeSamples()
                            } else {
                                model.removeRoot(root.id)
                            }
                        }
                    } label: {
                        if model.unavailableRoots.contains(root.id) {
                            Label("\(root.name) — not available", systemImage: "externaldrive.badge.xmark")
                        } else {
                            Label("\(root.name) — \((model.rootCounts[root.id] ?? 0).formatted())", systemImage: "folder")
                        }
                    }
                }
                if !model.roots.isEmpty { Divider() }
                Button("Add Folder…", systemImage: "folder.badge.plus") { showPicker = true }
                if !model.roots.isEmpty {
                    Button("Rescan All", systemImage: "arrow.clockwise") { model.rescan() }
                }
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .accessibilityLabel("Folders")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                model.favoritesOnly.toggle()
                MobileFeedback.play(.tick, settings: settings)
            } label: {
                Image(systemName: model.favoritesOnly ? "heart.fill" : "heart")
            }
            .accessibilityLabel("Favorites only")

            Menu {
                Section("Sort") {
                    ForEach(SortMode.allCases) { mode in
                        Button {
                            model.setSort(mode)
                        } label: {
                            if settings.sortMode == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                }
                Section("Show") {
                    ForEach(MediaGroup.allCases) { group in
                        Toggle(isOn: Binding(
                            get: { settings.isVisible(group) },
                            set: { settings.setVisible(group, $0) }
                        )) {
                            Text("\(group.title) (\((model.groupCounts[group] ?? 0).formatted()))")
                        }
                    }
                }
                Section("Columns") {
                    Stepper("\(settings.columnsOnPhone) columns", value: $settings.columnsOnPhone, in: 1...12)
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Sort and filter")

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            MobileGlyph().frame(width: 76, height: 76)
            Text("Start with a folder")
                .font(.system(.title2, design: .rounded).weight(.semibold))
            Text("FlatGrid opens every image and video inside it, at any depth, as one scrolling grid. Nothing is imported, copied or changed.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
            Button {
                showPicker = true
            } label: {
                Text("Choose Folder…")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(MobileTheme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            Button {
                services.loadSamples()
            } label: {
                if services.isBuildingSamples {
                    HStack(spacing: 8) { ProgressView(); Text("Creating samples…") }
                } else {
                    Text("Try it with a sample library")
                }
            }
            .font(.footnote)
            .disabled(services.isBuildingSamples)
            Text("Folders come from the Files app: On My iPhone, iCloud Drive or a connected drive.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 36)
        }
        .padding(.vertical, 30)
    }

    private var nothingToShow: some View {
        VStack(spacing: 6) {
            if model.isScanning {
                ProgressView().padding(.bottom, 4)
                Text("Looking through folders…").font(.headline)
            } else if !model.searchText.isEmpty {
                Text("No matches").font(.headline)
                Text("Nothing matches “\(model.searchText)”.").font(.footnote).foregroundStyle(.secondary)
            } else if model.favoritesOnly {
                Text("No favorites yet").font(.headline)
                Text("Touch and hold an item to add it.").font(.footnote).foregroundStyle(.secondary)
            } else if model.allItems.isEmpty {
                Text("No media found").font(.headline)
                Text("These folders hold no supported images or videos.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Everything is filtered out").font(.headline)
                Text("Turn a file type back on to see items.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}

struct MobileGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let unit = proxy.size.width / 3
            let gap = unit * 0.1
            ZStack(alignment: .topLeading) {
                ForEach(0..<9, id: \.self) { index in
                    RoundedRectangle(cornerRadius: unit * 0.16)
                        .fill(index == 4 ? MobileTheme.accent : Color.primary.opacity(0.1 + Double((index * 5) % 4) * 0.06))
                        .frame(width: unit - gap, height: unit - gap)
                        .offset(x: CGFloat(index % 3) * unit + gap / 2, y: CGFloat(index / 3) * unit + gap / 2)
                }
            }
        }
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}

struct MobileSettingsView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var services: MobileServices
    @Environment(\.dismiss) private var dismiss
    @Binding var showPicker: Bool
    @State private var cacheSize: Int64?

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(AppSettings.Theme.allCases) { Text($0.title).tag($0) }
                    }
                    Stepper("Columns: \(settings.columnsOnPhone)", value: $settings.columnsOnPhone, in: 1...12)
                    Toggle("Crop thumbnails to fill their tile", isOn: $settings.cropThumbnails)
                }
                Section("Feedback") {
                    Toggle("Interface sounds", isOn: $settings.uiSounds)
                    Toggle("Haptics", isOn: $settings.haptics)
                }
                Section("Video") {
                    Toggle("Play automatically when opened", isOn: $settings.videoAutoplay)
                    Toggle("Start muted", isOn: $settings.videoMuted)
                }
                Section {
                    ForEach(MediaGroup.allCases) { group in
                        Toggle(isOn: Binding(
                            get: { settings.isVisible(group) },
                            set: { settings.setVisible(group, $0) }
                        )) {
                            Text("\(group.title) · \((model.groupCounts[group] ?? 0).formatted())")
                        }
                    }
                } header: {
                    Text("File types shown in the grid")
                } footer: {
                    Text("Layered documents (PDF, PSD, AI, Procreate) are off until you turn them on.")
                }
                Section("Folders") {
                    ForEach(model.roots) { root in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(root.name)
                            Spacer()
                            Text((model.rootCounts[root.id] ?? 0).formatted()).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        for root in offsets.map({ model.roots[$0] }) {
                            if root.name == MobileServices.sampleFolderName {
                                services.removeSamples()
                            } else {
                                model.removeRoot(root.id)
                            }
                        }
                    }
                    Button("Add Folder…") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showPicker = true }
                    }
                }
                Section {
                    HStack {
                        Text("Thumbnail cache")
                        Spacer()
                        Text(cacheSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                            .foregroundStyle(.secondary)
                    }
                    Button("Clear Thumbnail Cache", role: .destructive) {
                        ThumbnailPipeline.shared.clearCache()
                        refreshCacheSize()
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("FlatGrid only reads your files. Its settings, favorites and thumbnail cache stay inside the app, and it makes no network connections.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear(perform: refreshCacheSize)
        }
    }

    private func refreshCacheSize() {
        cacheSize = nil
        DispatchQueue.global(qos: .utility).async {
            let size = ThumbnailPipeline.shared.diskCacheSize()
            DispatchQueue.main.async { cacheSize = size }
        }
    }
}
