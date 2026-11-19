import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var settings: AppSettings
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                VStack(spacing: 0) {
                    if !model.interfaceHidden { TopBar() }
                    ZStack {
                        Theme.canvas
                        if model.roots.isEmpty {
                            EmptyLibraryView()
                        } else {
                            GridView(model: model, settings: settings)
                            if model.visible.isEmpty {
                                NothingToShowView()
                            }
                        }
                    }
                    if !model.interfaceHidden { StatusBar() }
                }
                if model.viewerIndex != nil {
                    ViewerOverlay()
                        .transition(.opacity)
                }
                if let notice = model.notice {
                    NoticeBubble(text: notice)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            if model.showInfo {
                Rectangle().fill(Theme.hairline).frame(width: 1)
                InfoPanel()
                    .frame(width: 290)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Theme.canvas)
        .ignoresSafeArea()
        .frame(minWidth: 780, minHeight: 500)
        .animation(.easeOut(duration: 0.16), value: model.viewerIndex != nil)
        .animation(.easeOut(duration: 0.16), value: model.showInfo)
        .animation(.easeOut(duration: 0.14), value: model.notice)
        .animation(.easeOut(duration: 0.16), value: model.interfaceHidden)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .background(WindowAccessor { AppServices.shared.attach($0) })
        .sheet(isPresented: $model.showShortcuts) { ShortcutsView() }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
                DispatchQueue.main.async { AppServices.shared.model.addFolder(url) }
            }
        }
        return accepted
    }
}

// MARK: - Bridges

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { onWindow(window) }
    }
}

/// Lets a custom bar move the window, the way a title bar would.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.zoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct GridView: NSViewControllerRepresentable {
    @ObservedObject var model: LibraryModel
    @ObservedObject var settings: AppSettings

    final class Coordinator {
        var visibleVersion = -1
        var favoritesVersion = -1
        var sortMode: SortMode?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> GridViewController {
        let controller = GridViewController()
        let model = self.model
        controller.isFavorite = { model.isFavorite($0) }
        controller.onOpen = { index in
            model.open(index)
            Feedback.play(.open, settings: model.settings)
        }
        controller.onSelectionChange = { index in
            if model.selectedIndex != index { model.selectedIndex = index }
        }
        controller.onMagnify = { amount in
            model.adjustThumbnailSize(by: 1 + Double(amount))
        }
        controller.menuProvider = { AppServices.shared.contextMenu(for: $0) }
        controller.onHover = { _ in
            if model.settings.hoverSound { Sounds.shared.hover() }
        }
        controller.layout.targetSide = settings.thumbnailSize
        AppServices.shared.grid = controller
        return controller
    }

    func updateNSViewController(_ controller: GridViewController, context: Context) {
        let coordinator = context.coordinator
        controller.hoverEnabled = model.viewerIndex == nil
        controller.setCrop(settings.cropThumbnails)
        controller.setThumbSide(settings.thumbnailSize)
        if coordinator.visibleVersion != model.visibleVersion {
            let sortChanged = coordinator.sortMode != nil && coordinator.sortMode != settings.sortMode
            coordinator.visibleVersion = model.visibleVersion
            coordinator.sortMode = settings.sortMode
            coordinator.favoritesVersion = model.favoritesVersion
            controller.setItems(model.visible, selected: model.selectedIndex, resetScroll: sortChanged)
        } else {
            if coordinator.favoritesVersion != model.favoritesVersion {
                coordinator.favoritesVersion = model.favoritesVersion
                controller.refreshFavorites()
            }
            if controller.selectedIndex != model.selectedIndex {
                controller.select(model.selectedIndex, scroll: true)
            }
        }
    }
}

// MARK: - States

struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 18) {
            GridGlyph()
                .frame(width: 84, height: 84)
            Text("Start with a folder")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
            Text("FlatGrid opens every image and video inside it, at any depth, as one scrolling grid.\nNothing is imported, copied or changed.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
            Button {
                AppServices.shared.chooseFolders()
            } label: {
                Text("Choose Folder…")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Text("or drop folders anywhere in this window")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }
}

/// The app's own mark: tiles of different sizes settling into one grid.
struct GridGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let unit = proxy.size.width / 3
            let gap = unit * 0.1
            ZStack(alignment: .topLeading) {
                ForEach(0..<9, id: \.self) { index in
                    let row = index / 3
                    let column = index % 3
                    RoundedRectangle(cornerRadius: unit * 0.16)
                        .fill(index == 4 ? Theme.accent : Color.primary.opacity(0.1 + Double((index * 5) % 4) * 0.06))
                        .frame(width: unit - gap, height: unit - gap)
                        .offset(x: CGFloat(column) * unit + gap / 2, y: CGFloat(row) * unit + gap / 2)
                }
            }
        }
    }
}

struct NothingToShowView: View {
    @EnvironmentObject private var model: LibraryModel

    private var message: (String, String) {
        if model.isScanning { return ("Looking through folders…", "\(model.scanProgress.formatted()) files found so far") }
        if !model.searchText.isEmpty { return ("No matches", "Nothing in the library matches “\(model.searchText)”.") }
        if model.favoritesOnly { return ("No favorites yet", "Press F on any item to keep it here.") }
        if model.allItems.isEmpty { return ("No media found", "These folders hold no supported images or videos.") }
        return ("Everything is filtered out", "Turn a file type back on to see items.")
    }

    var body: some View {
        VStack(spacing: 6) {
            if model.isScanning { ProgressView().controlSize(.small).padding(.bottom, 6) }
            Text(message.0).font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(message.1).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

struct NoticeBubble: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .padding(.bottom, 84)
        }
        .allowsHitTesting(false)
    }
}
