import AppKit
import AVKit
import AVFoundation
import ImageIO

/// Keeps the document centred when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        if rect.width > documentView.frame.width {
            rect.origin.x = (documentView.frame.width - rect.width) / 2
        }
        if rect.height > documentView.frame.height {
            rect.origin.y = (documentView.frame.height - rect.height) / 2
        }
        return rect
    }
}

/// The scroll view's document: one layer holding the image, sized in points so that
/// magnification 1.0 means one image pixel per device pixel.
final class ImageDocumentView: NSView {
    let imageLayer = CALayer()
    private(set) var animatedView: NSImageView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(size: CGSize, turns: Int) {
        let quarterTurned = turns % 2 != 0
        let frameSize = quarterTurned ? CGSize(width: size.height, height: size.width) : size
        setFrameSize(frameSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.bounds = CGRect(origin: .zero, size: size)
        imageLayer.position = CGPoint(x: frameSize.width / 2, y: frameSize.height / 2)
        imageLayer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
        CATransaction.commit()
        if let animatedView {
            animatedView.frameCenterRotation = 0
            animatedView.frame = CGRect(
                x: (frameSize.width - size.width) / 2, y: (frameSize.height - size.height) / 2,
                width: size.width, height: size.height
            )
            animatedView.frameCenterRotation = -CGFloat(turns) * 90
        }
    }

    func setAnimatedImage(_ image: NSImage?) {
        animatedView?.removeFromSuperview()
        animatedView = nil
        guard let image else { return }
        let view = NSImageView(frame: bounds)
        view.imageScaling = .scaleAxesIndependently
        view.animates = true
        view.image = image
        addSubview(view)
        animatedView = view
    }
}

/// Full-view display of one item: zoomable image, or inline video.
final class ViewerHostView: NSView {
    private let scrollView = NSScrollView()
    private let documentView = ImageDocumentView(frame: .zero)
    private let messageLabel = NSTextField(labelWithString: "")
    private var playerView: AVPlayerView?
    private var player: AVPlayer?
    private var loopObserver: NSObjectProtocol?
    private var magnifyObserver: NSObjectProtocol?

    private var item: MediaItem?
    private var loadToken = 0
    private var pixelSize: CGSize = .zero
    private var loadedLongestEdge = 0
    private var loadingFull = false
    private var turns = 0
    private var actualSize = false
    private var userZoomed = false
    private var lastLaidOutSize: CGSize = .zero

    /// Called when a pinch or double-click changes whether the image is at 100%.
    var onActualSizeChange: ((Bool) -> Void)?
    /// Called when the zoom level changes on purpose: true for zooming in, false for out.
    var onZoom: ((Bool) -> Void)?
    private var settledMagnification: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = documentView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 32
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.alignment = .center
        messageLabel.isHidden = true
        addSubview(messageLabel)

        magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main
        ) { [weak self] _ in
            self?.liveMagnifyEnded()
        }

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        scrollView.addGestureRecognizer(doubleClick)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let magnifyObserver { NotificationCenter.default.removeObserver(magnifyObserver) }
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func layout() {
        super.layout()
        messageLabel.frame = CGRect(x: 20, y: bounds.midY - 12, width: max(0, bounds.width - 40), height: 24)
        if bounds.size != lastLaidOutSize {
            lastLaidOutSize = bounds.size
            if !actualSize && !userZoomed { applyMagnification(animated: false) }
        }
    }

    // MARK: Public state

    func update(item newItem: MediaItem?, turns newTurns: Int, actualSize newActualSize: Bool, autoplay: Bool, muted: Bool) {
        if newItem?.path != item?.path {
            turns = newTurns
            actualSize = newActualSize
            userZoomed = false
            show(newItem, autoplay: autoplay, muted: muted)
            return
        }
        if newTurns != turns {
            turns = newTurns
            layoutDocument()
            applyMagnification(animated: false)
        }
        if newActualSize != actualSize {
            actualSize = newActualSize
            userZoomed = false
            let before = scrollView.magnification
            applyMagnification(animated: true)
            if abs(settledMagnification - before) > before * 0.03 { onZoom?(settledMagnification > before) }
            loadFullResolutionIfNeeded()
        }
        player?.isMuted = muted
    }

    func stopPlayback() {
        player?.pause()
    }

    // MARK: Loading

    private func show(_ newItem: MediaItem?, autoplay: Bool, muted: Bool) {
        loadToken += 1
        let token = loadToken
        tearDownVideo()
        documentView.setAnimatedImage(nil)
        messageLabel.isHidden = true
        item = newItem
        pixelSize = .zero
        loadedLongestEdge = 0
        loadingFull = false

        guard let newItem else {
            documentView.imageLayer.contents = nil
            return
        }
        if newItem.group == .video {
            scrollView.isHidden = true
            showVideo(newItem, autoplay: autoplay, muted: muted)
            return
        }
        scrollView.isHidden = false

        // Something on screen straight away: whatever thumbnail is already in memory.
        if let standIn = ThumbnailPipeline.shared.bestCached(newItem, preferring: 1024) {
            pixelSize = CGSize(width: standIn.width, height: standIn.height)
            documentView.imageLayer.contents = standIn
            layoutDocument()
            applyMagnification(animated: false)
        } else {
            documentView.imageLayer.contents = nil
        }

        let scale = backingScale
        let screenEdge = max(Int(max(bounds.width, bounds.height) * scale), 512)
        let wantsFull = actualSize
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let size = ImageLoader.pixelSize(of: newItem)
            let image = ImageLoader.load(newItem, maxPixel: wantsFull ? nil : screenEdge)
            var animated: NSImage?
            if newItem.fileExtension == "gif",
               let source = CGImageSourceCreateWithURL(newItem.url as CFURL, nil),
               CGImageSourceGetCount(source) > 1 {
                animated = NSImage(contentsOf: newItem.url)
            }
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                guard let image else {
                    if self.documentView.imageLayer.contents == nil {
                        self.messageLabel.stringValue = "No preview available for this file"
                        self.messageLabel.isHidden = false
                    }
                    return
                }
                self.pixelSize = size ?? CGSize(width: image.width, height: image.height)
                self.loadedLongestEdge = max(image.width, image.height)
                self.documentView.imageLayer.contents = animated == nil ? image : nil
                self.documentView.setAnimatedImage(animated)
                self.layoutDocument()
                self.applyMagnification(animated: false)
            }
        }
    }

    private func loadFullResolutionIfNeeded() {
        guard let item, item.group != .video, !loadingFull, pixelSize != .zero else { return }
        let longest = Int(max(pixelSize.width, pixelSize.height))
        let needed = Int(CGFloat(longest) * scrollView.magnification)
        guard loadedLongestEdge < min(longest, ImageLoader.maxDimension),
              Double(needed) > Double(loadedLongestEdge) * 1.1 else { return }
        loadingFull = true
        let token = loadToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = ImageLoader.load(item, maxPixel: nil)
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                self.loadingFull = false
                guard let image else { return }
                self.loadedLongestEdge = max(max(image.width, image.height), longest)
                if self.documentView.animatedView == nil {
                    self.documentView.imageLayer.contents = image
                }
            }
        }
    }

    // MARK: Geometry

    private func layoutDocument() {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        let scale = backingScale
        documentView.apply(size: CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale), turns: turns)
    }

    /// Magnification that fits the whole image, never enlarging past one image pixel per point.
    private var fitMagnification: CGFloat {
        let doc = documentView.frame.size
        let area = scrollView.bounds.size
        guard doc.width > 0, doc.height > 0, area.width > 0, area.height > 0 else { return 1 }
        return min(min(area.width / doc.width, area.height / doc.height), backingScale)
    }

    private func applyMagnification(animated: Bool) {
        guard documentView.frame.width > 0 else { return }
        let fit = fitMagnification
        scrollView.minMagnification = min(fit, 1) * 0.5
        let target: CGFloat = actualSize ? 1 : fit
        settledMagnification = target
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                scrollView.animator().magnification = target
            }
        } else {
            scrollView.magnification = target
        }
    }

    private func liveMagnifyEnded() {
        let magnification = scrollView.magnification
        if abs(magnification - settledMagnification) > settledMagnification * 0.05 {
            onZoom?(magnification > settledMagnification)
        }
        settledMagnification = magnification
        let fit = fitMagnification
        userZoomed = abs(magnification - fit) > 0.01
        let nowActual = abs(magnification - 1) < 0.02 && abs(fit - 1) > 0.02
        if nowActual != actualSize {
            actualSize = nowActual
            onActualSizeChange?(nowActual)
        }
        loadFullResolutionIfNeeded()
    }

    @objc private func handleDoubleClick() {
        guard item?.group != .video else { return }
        onActualSizeChange?(!actualSize)
    }

    // MARK: Video

    private func showVideo(_ item: MediaItem, autoplay: Bool, muted: Bool) {
        let view = AVPlayerView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        let newPlayer = AVPlayer(url: item.url)
        newPlayer.isMuted = muted
        newPlayer.actionAtItemEnd = .none
        view.player = newPlayer
        addSubview(view, positioned: .below, relativeTo: messageLabel)
        playerView = view
        player = newPlayer
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: newPlayer.currentItem, queue: .main
        ) { [weak newPlayer] _ in
            newPlayer?.seek(to: .zero)
            if autoplay { newPlayer?.play() } else { newPlayer?.pause() }
        }
        if autoplay { newPlayer.play() }
    }

    private func tearDownVideo() {
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
        player?.pause()
        playerView?.player = nil
        playerView?.removeFromSuperview()
        playerView = nil
        player = nil
    }

    func togglePlayback() {
        guard let player else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
    }
}
