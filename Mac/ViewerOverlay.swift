import AppKit
import SwiftUI

struct ViewerRepresentable: NSViewRepresentable {
    let item: MediaItem
    let turns: Int
    let actualSize: Bool
    let autoplay: Bool
    let muted: Bool
    let onActualSizeChange: (Bool) -> Void
    let onZoom: (Bool) -> Void

    func makeNSView(context: Context) -> ViewerHostView {
        let view = ViewerHostView(frame: .zero)
        view.onActualSizeChange = onActualSizeChange
        return view
    }

    func updateNSView(_ view: ViewerHostView, context: Context) {
        view.onActualSizeChange = onActualSizeChange
        view.onZoom = onZoom
        view.update(item: item, turns: turns, actualSize: actualSize, autoplay: autoplay, muted: muted)
    }

    static func dismantleNSView(_ view: ViewerHostView, coordinator: ()) {
        view.update(item: nil, turns: 0, actualSize: false, autoplay: false, muted: true)
    }
}

struct ViewerOverlay: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var settings: AppSettings

    private var item: MediaItem? {
        guard let index = model.viewerIndex, model.visible.indices.contains(index) else { return nil }
        return model.visible[index]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let item {
                if !model.interfaceHidden { chrome(item) }
                ViewerRepresentable(
                    item: item,
                    turns: model.rotation(for: item),
                    actualSize: model.actualSize,
                    autoplay: settings.videoAutoplay,
                    muted: settings.videoMuted,
                    onActualSizeChange: { model.actualSize = $0 },
                    onZoom: { zoomedIn in
                        if settings.uiSounds { Sounds.shared.play(zoomedIn ? .zoomIn : .zoomOut) }
                    }
                )
                .id(item.path)
                .transition(slide)
            } else {
                Spacer()
            }
        }
        .background(Theme.canvas)
        .clipped()
        .animation(settings.slideTransition ? .easeOut(duration: 0.22) : nil, value: item?.path)
    }

    /// New item comes in from the side you are moving towards; the old one leaves the other way.
    private var slide: AnyTransition {
        guard settings.slideTransition else { return .identity }
        let forward = model.movedForward
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading),
            removal: .move(edge: forward ? .leading : .trailing)
        )
    }

    private func chrome(_ item: MediaItem) -> some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 70)

            Button {
                model.closeViewer()
                Feedback.play(.close, settings: settings)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.3x3")
                    Text("Grid")
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("Back to the grid (Space)")

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(item.folderName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.leading, 4)

            Spacer(minLength: 8)

            if let index = model.viewerIndex {
                Text("\((index + 1).formatted()) / \(model.visible.count.formatted())")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            }

            HStack(spacing: 4) {
                BarButton(symbol: "chevron.left", help: "Previous item (←)") { model.step(-1) }
                BarButton(symbol: "chevron.right", help: "Next item (→)") { model.step(1) }
            }
            HStack(spacing: 4) {
                BarButton(symbol: model.isFavorite(item) ? "heart.fill" : "heart", isOn: model.isFavorite(item), help: "Favorite (F)") {
                    AppServices.shared.toggleFavorite(item)
                }
                if item.group != .video {
                    BarButton(symbol: "1.magnifyingglass", isOn: model.actualSize, help: "Original size (Z)") {
                        model.actualSize.toggle()
                    }
                    BarButton(symbol: "rotate.left", help: "Rotate left ([)") { model.rotate(item, clockwise: false) }
                    BarButton(symbol: "rotate.right", help: "Rotate right (])") { model.rotate(item, clockwise: true) }
                }
                BarButton(symbol: "info.circle", isOn: model.showInfo, help: "Get info (I)") { model.showInfo.toggle() }
                BarButton(symbol: "arrow.up.forward.app", help: "Reveal in Finder (R)") { AppServices.shared.reveal(item) }
            }
        }
        .padding(.trailing, 12)
        .frame(height: 46)
        .background(WindowDragArea())
        .background(Theme.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .id(model.favoritesVersion)
    }
}

struct InfoPanel: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var rows: [InfoRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Info").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    model.showInfo = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            if let item = model.currentItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .semibold))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.label.uppercased())
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(row.value)
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        HStack(spacing: 8) {
                            Button("Reveal in Finder") { AppServices.shared.reveal(item) }
                            Button("Copy") { AppServices.shared.copy(item) }
                        }
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .task(id: item.path) {
                    rows = await MetadataReader.details(for: item)
                }
            } else {
                VStack {
                    Spacer()
                    Text("Select an item to see its details")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.bar)
    }
}
