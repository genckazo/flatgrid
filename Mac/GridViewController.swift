import AppKit

// MARK: - Layout

/// Uniform square grid. Every frame is computed from the item index, so layout cost depends on
/// what is on screen, not on how many items the library holds.
final class GridLayout {
    var targetSide: CGFloat = 150

    private(set) var columns = 1
    private(set) var side: CGFloat = 150
    private(set) var spacing: CGFloat = 2
    private(set) var rowHeight: CGFloat = 152
    private(set) var count = 0
    private(set) var width: CGFloat = 0
    private var leading: CGFloat = 0

    func update(width newWidth: CGFloat, count newCount: Int) {
        count = newCount
        width = max(1, newWidth)
        // Images float on the background; the gap grows with the tile so large previews breathe.
        spacing = targetSide < 48 ? 2 : max(4, (targetSide * 0.13).rounded())
        let available = max(1, width - spacing * 2)
        columns = max(1, Int((available + spacing) / (targetSide + spacing)))
        side = max(8, floor((available - CGFloat(columns - 1) * spacing) / CGFloat(columns)))
        let used = CGFloat(columns) * side + CGFloat(columns - 1) * spacing
        leading = max(0, floor((width - used) / 2))
        rowHeight = side + spacing
    }

    var rows: Int { count == 0 ? 0 : (count + columns - 1) / columns }
    var contentHeight: CGFloat { CGFloat(rows) * rowHeight + spacing }

    func frame(for index: Int) -> CGRect {
        let row = index / columns
        let column = index % columns
        return CGRect(
            x: leading + CGFloat(column) * (side + spacing),
            y: spacing + CGFloat(row) * rowHeight,
            width: side,
            height: side
        )
    }

    /// Indices whose rows intersect `rect`.
    func indexRange(in rect: CGRect) -> Range<Int> {
        guard count > 0, rowHeight > 0 else { return 0..<0 }
        let firstRow = max(0, Int(floor((rect.minY - spacing) / rowHeight)))
        let lastRow = min(rows - 1, Int(floor((rect.maxY - spacing) / rowHeight)))
        guard firstRow <= lastRow else { return 0..<0 }
        return (firstRow * columns)..<min(count, (lastRow + 1) * columns)
    }

    func index(at point: CGPoint) -> Int? {
        guard count > 0, point.y >= spacing, point.x >= leading else { return nil }
        let row = Int((point.y - spacing) / rowHeight)
        let column = Int((point.x - leading) / (side + spacing))
        guard column < columns else { return nil }
        let index = row * columns + column
        guard index < count, frame(for: index).contains(point) else { return nil }
        return index
    }
}

// MARK: - Tile

/// One thumbnail: a single layer whose contents is an already-decoded image. Tiles are recycled
/// as the grid scrolls; nothing is drawn on the main thread.
final class TileLayer: CALayer {
    var index = -1
    var path: String?
    var token: ThumbnailPipeline.Token?
    private var favoriteLayer: CALayer?
    private var videoLayer: CAShapeLayer?
    private var labelLayer: CATextLayer?
    private var isFavorite = false
    private var isVideo = false
    private var labelText: String?

    override init() {
        super.init()
        masksToBounds = true
        contentsGravity = .resizeAspect
        minificationFilter = .linear
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// No implicit animations: frames and contents change instantly while scrolling.
    override func action(forKey event: String) -> CAAction? { nil }

    func setBadges(favorite: Bool, video: Bool, label: String?, scale: CGFloat, labelColor: CGColor) {
        isFavorite = favorite
        isVideo = video
        labelText = label
        layoutBadges(scale: scale, labelColor: labelColor)
    }

    func setFavorite(_ favorite: Bool, scale: CGFloat, labelColor: CGColor) {
        guard favorite != isFavorite else { return }
        isFavorite = favorite
        layoutBadges(scale: scale, labelColor: labelColor)
    }

    func showLabel(_ text: String, scale: CGFloat, labelColor: CGColor) {
        labelText = text
        layoutBadges(scale: scale, labelColor: labelColor)
    }

    /// Coordinates are top-left based: the grid's document view is flipped.
    func layoutBadges(scale: CGFloat, labelColor: CGColor) {
        let side = bounds.width
        let showBadges = side >= 44

        if isFavorite && showBadges {
            let badge = favoriteLayer ?? {
                let created = CALayer()
                created.actions = TileLayer.noActions
                created.backgroundColor = Theme.nsAccent.cgColor
                created.borderColor = CGColor(gray: 1, alpha: 0.9)
                created.borderWidth = 1.5
                addSublayer(created)
                favoriteLayer = created
                return created
            }()
            let size = min(14, max(8, side / 12))
            let inset = max(5, side / 22)
            badge.frame = CGRect(x: side - inset - size, y: inset, width: size, height: size)
            badge.cornerRadius = size / 2
            badge.isHidden = false
        } else {
            favoriteLayer?.isHidden = true
        }

        if isVideo && showBadges {
            let glyph = videoLayer ?? {
                let created = CAShapeLayer()
                created.actions = TileLayer.noActions
                created.fillColor = CGColor(gray: 1, alpha: 1)
                created.shadowColor = CGColor(gray: 0, alpha: 1)
                created.shadowOpacity = 0.55
                created.shadowRadius = 2
                created.shadowOffset = .zero
                addSublayer(created)
                videoLayer = created
                return created
            }()
            let size = min(16, max(9, side / 11))
            let inset = max(5, side / 22)
            glyph.frame = CGRect(x: inset, y: bounds.height - inset - size, width: size, height: size)
            let triangle = CGMutablePath()
            triangle.move(to: CGPoint(x: 0, y: 0))
            triangle.addLine(to: CGPoint(x: size, y: size / 2))
            triangle.addLine(to: CGPoint(x: 0, y: size))
            triangle.closeSubpath()
            glyph.path = triangle
            glyph.isHidden = false
        } else {
            videoLayer?.isHidden = true
        }

        if let labelText, side >= 36 {
            let label = labelLayer ?? {
                let created = CATextLayer()
                created.actions = TileLayer.noActions
                created.alignmentMode = .center
                created.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
                addSublayer(created)
                labelLayer = created
                return created
            }()
            let fontSize = min(15, max(8, side / 9))
            label.fontSize = fontSize
            label.contentsScale = scale
            label.foregroundColor = labelColor
            label.string = labelText
            label.frame = CGRect(x: 0, y: (bounds.height - fontSize * 1.4) / 2, width: side, height: fontSize * 1.4)
            label.isHidden = false
        } else {
            labelLayer?.isHidden = true
        }
    }

    func clear() {
        removeAllAnimations()
        contents = nil
        path = nil
        index = -1
        labelText = nil
        favoriteLayer?.isHidden = true
        videoLayer?.isHidden = true
        labelLayer?.isHidden = true
    }

    static let noActions: [String: CAAction] = [
        "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
        "hidden": NSNull(), "opacity": NSNull(), "string": NSNull(), "path": NSNull(),
        "cornerRadius": NSNull(), "fontSize": NSNull(), "foregroundColor": NSNull(),
    ]
}

// MARK: - Document view

final class GridDocumentView: NSView {
    weak var controller: GridViewController?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {}

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        controller?.handleClick(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.menu(at: convert(event.locationInWindow, from: nil))
    }

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.handleHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        controller?.handleHover(at: nil)
    }

    override func magnify(with event: NSEvent) {
        controller?.onMagnify?(event.magnification)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        controller?.refreshColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        controller?.backingChanged()
    }
}

// MARK: - Controller

/// The grid. A scroll view over a plain document view; visible tiles are layers placed by index
/// and recycled on scroll. Cost per frame is proportional to the tiles that changed.
final class GridViewController: NSViewController {
    let scrollView = NSScrollView()
    let documentView = GridDocumentView()
    let layout = GridLayout()
    var pipeline = ThumbnailPipeline.shared

    private(set) var items: [MediaItem] = []
    var isFavorite: (MediaItem) -> Bool = { _ in false }
    var onOpen: ((Int) -> Void)?
    var onSelectionChange: ((Int?) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?
    /// Called when the cursor moves onto a different thumbnail.
    var onHover: ((Int) -> Void)?

    /// Off while an item is open in the viewer, which sits on top of the grid.
    var hoverEnabled = true {
        didSet { if !hoverEnabled { hoverIndex = nil; hoverLayer.isHidden = true } }
    }
    private var hoverIndex: Int?
    private let hoverLayer = CALayer()
    private(set) var selectedIndex: Int?
    private var tiles: [Int: TileLayer] = [:]
    private var pool: [TileLayer] = []
    private var shownRange: Range<Int> = 0..<0
    private var prefetchTokens: [Int: ThumbnailPipeline.Token] = [:]
    private var prefetchRange: Range<Int> = 0..<0
    private var lastOffset: CGFloat = 0
    private let selectionLayer = CALayer()
    private var crop = false
    private var bucket = 256
    private var tileColor = CGColor(gray: 0.5, alpha: 0.06)
    private var labelColor = CGColor(gray: 0.5, alpha: 1)
    private var boundsObserver: NSObjectProtocol?

    var columns: Int { layout.columns }
    var itemCount: Int { items.count }
    var visibleTileCount: Int { tiles.count }
    var visibleIndexRange: Range<Int> { shownRange }

    override func loadView() {
        documentView.controller = self
        documentView.wantsLayer = true
        documentView.layerContentsRedrawPolicy = .never

        selectionLayer.actions = TileLayer.noActions
        selectionLayer.borderColor = Theme.nsAccent.cgColor
        selectionLayer.zPosition = 10
        selectionLayer.isHidden = true
        documentView.layer?.addSublayer(selectionLayer)

        hoverLayer.actions = TileLayer.noActions
        hoverLayer.borderColor = CGColor(gray: 1, alpha: 0.75)
        hoverLayer.zPosition = 9
        hoverLayer.isHidden = true
        documentView.layer?.addSublayer(hoverLayer)

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil
        ) { [weak self] _ in
            self?.updateVisibleTiles()
        }
        view = scrollView
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if abs(scrollView.contentView.bounds.width - layout.width) > 0.5 {
            relayout(keepingAnchor: true)
        } else {
            updateVisibleTiles()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshColors()
        relayout(keepingAnchor: false)
    }

    private var backingScale: CGFloat {
        view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    // MARK: Geometry

    /// Recomputes the grid for the current width and item count and repositions every tile.
    private func relayout(keepingAnchor: Bool) {
        let clip = scrollView.contentView
        let anchor = keepingAnchor ? anchorIndex() : nil
        let anchorOffset = anchor.map { layout.frame(for: $0).minY - clip.bounds.minY } ?? 0

        layout.update(width: clip.bounds.width, count: items.count)
        documentView.setFrameSize(NSSize(width: clip.bounds.width, height: max(layout.contentHeight, 1)))
        bucket = ThumbnailPipeline.bucket(forPixelSide: layout.side * backingScale)

        if let anchor, anchor < items.count {
            let maxY = max(0, layout.contentHeight - clip.bounds.height)
            let y = min(max(0, layout.frame(for: anchor).minY - anchorOffset), maxY)
            clip.setBoundsOrigin(NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
        }
        rebuildTiles()
    }

    private func anchorIndex() -> Int? {
        guard !items.isEmpty, layout.rowHeight > 0, layout.count > 0 else { return nil }
        let bounds = scrollView.contentView.bounds
        if let selectedIndex, selectedIndex < layout.count, layout.frame(for: selectedIndex).intersects(bounds) {
            return selectedIndex
        }
        let row = max(0, Int((bounds.minY - layout.spacing) / layout.rowHeight))
        return min(layout.count - 1, row * layout.columns)
    }

    /// Throws away every tile and builds the visible ones again (items, size or crop changed).
    private func rebuildTiles() {
        for tile in tiles.values { recycle(tile) }
        tiles.removeAll(keepingCapacity: true)
        shownRange = 0..<0
        hoverIndex = nil
        hoverLayer.isHidden = true
        cancelPrefetches()
        updateVisibleTiles()
        positionSelection()
    }

    /// Called on every scroll step. Recycles tiles that left and configures tiles that entered.
    func updateVisibleTiles() {
        guard isViewLoaded else { return }
        let bounds = scrollView.contentView.bounds
        let overscan = max(layout.rowHeight * 2, bounds.height * 0.2)
        let range = layout.indexRange(in: bounds.insetBy(dx: 0, dy: -overscan))
        let scrollingDown = bounds.minY >= lastOffset
        lastOffset = bounds.minY
        guard range != shownRange else { return }

        for index in shownRange where !range.contains(index) {
            if let tile = tiles.removeValue(forKey: index) { recycle(tile) }
        }
        let scale = backingScale
        for index in range where tiles[index] == nil {
            let tile = pool.popLast() ?? makeTile()
            configure(tile, index: index, scale: scale)
            tiles[index] = tile
        }
        shownRange = range

        updatePrefetch(visible: range, scrollingDown: scrollingDown)
    }

    private func makeTile() -> TileLayer {
        let tile = TileLayer()
        documentView.layer?.addSublayer(tile)
        return tile
    }

    private func recycle(_ tile: TileLayer) {
        pipeline.cancel(tile.token)
        tile.token = nil
        tile.clear()
        tile.isHidden = true
        pool.append(tile)
    }

    private func configure(_ tile: TileLayer, index: Int, scale: CGFloat) {
        let item = items[index]
        tile.index = index
        tile.path = item.path
        tile.isHidden = false
        tile.frame = layout.frame(for: index)
        tile.contentsGravity = crop ? .resizeAspectFill : .resizeAspect
        tile.setBadges(favorite: isFavorite(item), video: item.group == .video, label: nil, scale: scale, labelColor: labelColor)

        if let ready = pipeline.cached(item, bucket: bucket) {
            tile.contents = ready
            tile.backgroundColor = nil
            return
        }
        let standIn = pipeline.bestCached(item, preferring: bucket)
        tile.contents = standIn
        // The faint box only shows while a thumbnail is still loading.
        tile.backgroundColor = standIn == nil ? tileColor : nil
        let expectedPath = item.path
        let fallback = item.fileExtension.uppercased()
        tile.token = pipeline.request(item, bucket: bucket) { [weak self, weak tile] image in
            guard let self, let tile, tile.path == expectedPath else { return }
            tile.token = nil
            if let image {
                tile.contents = image
                tile.backgroundColor = nil
                if standIn == nil {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0.35
                    fade.toValue = 1
                    fade.duration = 0.12
                    tile.add(fade, forKey: "fade")
                }
            } else if standIn == nil {
                tile.showLabel(fallback, scale: self.backingScale, labelColor: self.labelColor)
            }
        }
    }

    // MARK: Prefetch

    /// Warms thumbnails for roughly one more screen in the direction of travel, at low priority.
    private func updatePrefetch(visible: Range<Int>, scrollingDown: Bool) {
        let span = min(max(visible.count, layout.columns * 4), 600)
        let ahead: Range<Int>
        if scrollingDown {
            ahead = min(visible.upperBound, items.count)..<min(visible.upperBound + span, items.count)
        } else {
            ahead = max(visible.lowerBound - span, 0)..<max(visible.lowerBound, 0)
        }
        guard ahead != prefetchRange else { return }
        for (index, token) in prefetchTokens where !ahead.contains(index) {
            pipeline.cancel(token)
            prefetchTokens[index] = nil
        }
        for index in ahead where prefetchTokens[index] == nil {
            let item = items[index]
            guard pipeline.cached(item, bucket: bucket) == nil else { continue }
            prefetchTokens[index] = pipeline.request(item, bucket: bucket, lowPriority: true) { [weak self] _ in
                self?.prefetchTokens[index] = nil
            }
        }
        prefetchRange = ahead
    }

    private func cancelPrefetches() {
        for token in prefetchTokens.values { pipeline.cancel(token) }
        prefetchTokens.removeAll()
        prefetchRange = 0..<0
    }

    // MARK: Updates from the model

    func setItems(_ newItems: [MediaItem], selected: Int?, resetScroll: Bool) {
        items = newItems
        selectedIndex = selected.flatMap { $0 < newItems.count ? $0 : nil }
        guard isViewLoaded else { return }
        if resetScroll && selectedIndex == nil {
            scrollView.contentView.setBoundsOrigin(.zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        relayout(keepingAnchor: false)
        // Clamp the scroll position if the list got shorter.
        let clip = scrollView.contentView
        let maxY = max(0, layout.contentHeight - clip.bounds.height)
        if clip.bounds.minY > maxY {
            clip.setBoundsOrigin(NSPoint(x: 0, y: maxY))
            scrollView.reflectScrolledClipView(clip)
            updateVisibleTiles()
        }
        if let selectedIndex { scrollToItem(selectedIndex) }
    }

    func setThumbSide(_ side: CGFloat) {
        guard abs(layout.targetSide - side) > 0.01 else { return }
        layout.targetSide = side
        guard isViewLoaded else { return }
        relayout(keepingAnchor: true)
    }

    func setCrop(_ newValue: Bool) {
        guard newValue != crop else { return }
        crop = newValue
        guard isViewLoaded else { return }
        for tile in tiles.values { tile.contentsGravity = crop ? .resizeAspectFill : .resizeAspect }
    }

    func refreshFavorites() {
        let scale = backingScale
        for (index, tile) in tiles where index < items.count {
            tile.setFavorite(isFavorite(items[index]), scale: scale, labelColor: labelColor)
        }
    }

    func refreshColors() {
        guard isViewLoaded else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            tileColor = Theme.nsTile.cgColor
            labelColor = NSColor.secondaryLabelColor.cgColor
        }
        let scale = backingScale
        for tile in tiles.values {
            if tile.contents == nil { tile.backgroundColor = tileColor }
            tile.layoutBadges(scale: scale, labelColor: labelColor)
        }
    }

    func backingChanged() {
        guard isViewLoaded else { return }
        let wanted = ThumbnailPipeline.bucket(forPixelSide: layout.side * backingScale)
        if wanted != bucket { relayout(keepingAnchor: true) }
    }

    // MARK: Selection

    func select(_ index: Int?, scroll: Bool) {
        selectedIndex = index.flatMap { $0 < items.count ? $0 : nil }
        positionSelection()
        if scroll, let selectedIndex { scrollToItem(selectedIndex) }
    }

    private func positionSelection() {
        if let selectedIndex, selectedIndex < layout.count {
            selectionLayer.frame = layout.frame(for: selectedIndex)
            selectionLayer.borderWidth = max(2, min(4, layout.side / 28))
            selectionLayer.isHidden = false
        } else {
            selectionLayer.isHidden = true
        }
    }

    func scrollToItem(_ index: Int) {
        guard isViewLoaded, index < layout.count else { return }
        let clip = scrollView.contentView
        let frame = layout.frame(for: index).insetBy(dx: 0, dy: -layout.spacing * 2)
        var y = clip.bounds.minY
        if frame.minY < clip.bounds.minY {
            y = frame.minY
        } else if frame.maxY > clip.bounds.maxY {
            y = frame.maxY - clip.bounds.height
        } else {
            return
        }
        let maxY = max(0, layout.contentHeight - clip.bounds.height)
        clip.setBoundsOrigin(NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Mouse

    func handleHover(at point: CGPoint?) {
        guard hoverEnabled else { return }
        let index = point.flatMap { layout.index(at: $0) }
        guard index != hoverIndex else { return }
        hoverIndex = index
        if let index {
            hoverLayer.frame = layout.frame(for: index)
            hoverLayer.borderWidth = max(1, min(2, layout.side / 60))
            hoverLayer.isHidden = false
            onHover?(index)
        } else {
            hoverLayer.isHidden = true
        }
    }

    func handleClick(at point: CGPoint, clickCount: Int) {
        let index = layout.index(at: point)
        if index != selectedIndex {
            select(index, scroll: false)
            onSelectionChange?(index)
        }
        if clickCount == 2, let index { onOpen?(index) }
    }

    func menu(at point: CGPoint) -> NSMenu? {
        guard let index = layout.index(at: point) else { return nil }
        if index != selectedIndex {
            select(index, scroll: false)
            onSelectionChange?(index)
        }
        return menuProvider?(index)
    }
}
