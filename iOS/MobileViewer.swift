import SwiftUI
import UIKit
import AVKit
import AVFoundation

// MARK: - Pages

class MediaPage: UIViewController {
    let index: Int
    let item: MediaItem
    var onTap: (() -> Void)?
    var onActualSizeChange: ((Bool) -> Void)?

    init(index: Int, item: MediaItem) {
        self.index = index
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(turns: Int, actualSize: Bool, muted: Bool) {}
}

/// One zoomable image. At zoom 1.0 one image pixel covers one device pixel.
final class ImagePage: MediaPage, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let message = UILabel()
    private var cgImage: CGImage?
    private var pixelSize: CGSize = .zero
    private var loadedEdge = 0
    private var loadingFull = false
    private var turns = 0
    private var actualSize = false
    private var userZoomed = false
    private var laidOutSize: CGSize = .zero
    private var loadToken = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        view.addSubview(scrollView)
        scrollView.addSubview(imageView)

        message.textColor = .secondaryLabel
        message.font = .systemFont(ofSize: 14)
        message.textAlignment = .center
        message.numberOfLines = 0
        message.isHidden = true
        message.frame = view.bounds.insetBy(dx: 24, dy: 0)
        message.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(message)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.bounds.size != laidOutSize {
            laidOutSize = view.bounds.size
            layoutImage(keepZoom: false)
        }
    }

    private var screenScale: CGFloat { view.window?.screen.scale ?? traitCollection.displayScale }

    private func load() {
        loadToken += 1
        let token = loadToken
        let item = self.item
        if let standIn = ThumbnailPipeline.shared.bestCached(item, preferring: 1024) {
            cgImage = standIn
            pixelSize = CGSize(width: standIn.width, height: standIn.height)
            layoutImage(keepZoom: false)
        }
        let screen = UIScreen.main.nativeBounds.size
        let edge = max(Int(max(screen.width, screen.height)), 1024)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let size = ImageLoader.pixelSize(of: item)
            let image = ImageLoader.load(item, maxPixel: edge)
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                guard let image else {
                    if self.cgImage == nil {
                        self.message.text = "No preview available for this file"
                        self.message.isHidden = false
                    }
                    return
                }
                self.cgImage = image
                self.pixelSize = size ?? CGSize(width: image.width, height: image.height)
                self.loadedEdge = max(image.width, image.height)
                self.layoutImage(keepZoom: false)
            }
        }
    }

    private func loadFullIfNeeded() {
        guard !loadingFull, pixelSize != .zero else { return }
        let longest = Int(max(pixelSize.width, pixelSize.height))
        let needed = Double(longest) * Double(scrollView.zoomScale)
        guard loadedEdge < min(longest, ImageLoader.maxDimension), needed > Double(loadedEdge) * 1.1 else { return }
        loadingFull = true
        let token = loadToken
        let item = self.item
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = ImageLoader.load(item, maxPixel: nil)
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                self.loadingFull = false
                guard let image else { return }
                self.loadedEdge = max(max(image.width, image.height), longest)
                self.cgImage = image
                self.imageView.image = UIImage(cgImage: image, scale: 1, orientation: self.orientation)
            }
        }
    }

    private var orientation: UIImage.Orientation {
        switch turns % 4 {
        case 1: return .right
        case 2: return .down
        case 3: return .left
        default: return .up
        }
    }

    private var fitScale: CGFloat {
        let content = imageView.bounds.size
        let area = scrollView.bounds.size
        guard content.width > 0, content.height > 0, area.width > 0, area.height > 0 else { return 1 }
        return min(min(area.width / content.width, area.height / content.height), screenScale)
    }

    /// Sizes the image view in points so that zoom 1.0 is pixel-for-pixel, then applies fit or 100%.
    private func layoutImage(keepZoom: Bool) {
        guard let cgImage, pixelSize.width > 0, pixelSize.height > 0, isViewLoaded else { return }
        let scale = screenScale
        let quarterTurned = turns % 2 != 0
        let shown = quarterTurned ? CGSize(width: pixelSize.height, height: pixelSize.width) : pixelSize
        let points = CGSize(width: shown.width / scale, height: shown.height / scale)
        let previousZoom = scrollView.zoomScale

        scrollView.minimumZoomScale = 0.001
        scrollView.maximumZoomScale = 1000
        scrollView.zoomScale = 1
        imageView.image = UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
        imageView.frame = CGRect(origin: .zero, size: points)
        scrollView.contentSize = points

        let fit = fitScale
        scrollView.minimumZoomScale = fit
        scrollView.maximumZoomScale = max(fit * 6, 2)
        if keepZoom && userZoomed {
            scrollView.zoomScale = min(max(previousZoom, fit), scrollView.maximumZoomScale)
        } else {
            scrollView.zoomScale = actualSize ? max(1, fit) : fit
        }
        centerContent()
        message.isHidden = true
    }

    private func centerContent() {
        let area = scrollView.bounds.size
        let content = scrollView.contentSize
        let horizontal = max(0, (area.width - content.width) / 2)
        let vertical = max(0, (area.height - content.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    override func apply(turns newTurns: Int, actualSize newActualSize: Bool, muted: Bool) {
        guard isViewLoaded else {
            turns = newTurns
            actualSize = newActualSize
            return
        }
        if newTurns != turns {
            turns = newTurns
            userZoomed = false
            layoutImage(keepZoom: false)
        }
        if newActualSize != actualSize {
            actualSize = newActualSize
            userZoomed = false
            let target = actualSize ? max(1, fitScale) : fitScale
            scrollView.setZoomScale(target, animated: true)
            loadFullIfNeeded()
        }
    }

    // MARK: Gestures and zoom

    @objc private func singleTapped() { onTap?() }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        let fit = fitScale
        if scrollView.zoomScale > fit * 1.05 {
            scrollView.setZoomScale(fit, animated: true)
            setActual(false)
        } else {
            let target = max(1, fit * 2.5)
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / target, height: scrollView.bounds.height / target)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    private func setActual(_ value: Bool) {
        guard value != actualSize else { return }
        actualSize = value
        onActualSizeChange?(value)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        let fit = fitScale
        userZoomed = abs(scale - fit) > 0.01
        setActual(abs(scale - 1) < 0.02 && abs(fit - 1) > 0.02)
        loadFullIfNeeded()
    }
}

/// Inline video with the system transport controls.
final class VideoPage: MediaPage {
    private let playerController = AVPlayerViewController()
    private var player: AVPlayer?
    private var loopObserver: NSObjectProtocol?
    var autoplay = true

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let player = AVPlayer(url: item.url)
        player.actionAtItemEnd = .none
        self.player = player
        playerController.player = player
        playerController.videoGravity = .resizeAspect
        addChild(playerController)
        playerController.view.frame = view.bounds
        playerController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(playerController.view)
        playerController.didMove(toParent: self)
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.player?.seek(to: .zero)
            if self.autoplay { self.player?.play() } else { self.player?.pause() }
        }
    }

    deinit {
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if autoplay { player?.play() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player?.pause()
    }

    override func apply(turns: Int, actualSize: Bool, muted: Bool) {
        player?.isMuted = muted
    }
}

// MARK: - Pager

final class PagerController: UIPageViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    var model: LibraryModel?
    var settings: AppSettings?
    private var currentIndex = -1

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        dataSource = self
        delegate = self
    }

    private func makePage(_ index: Int) -> MediaPage? {
        guard let model, let settings, model.visible.indices.contains(index) else { return nil }
        let item = model.visible[index]
        let page: MediaPage
        if item.group == .video {
            let video = VideoPage(index: index, item: item)
            video.autoplay = settings.videoAutoplay
            page = video
        } else {
            page = ImagePage(index: index, item: item)
        }
        page.onTap = { [weak model] in model?.interfaceHidden.toggle() }
        page.onActualSizeChange = { [weak model] value in
            if model?.actualSize != value { model?.actualSize = value }
        }
        page.apply(turns: model.rotation(for: item), actualSize: false, muted: settings.videoMuted)
        return page
    }

    /// Brings the pager in line with the model after any change.
    func sync() {
        guard let model, let settings, let index = model.viewerIndex, model.visible.indices.contains(index) else { return }
        let shown = viewControllers?.first as? MediaPage
        if shown == nil || shown?.index != index || shown?.item.path != model.visible[index].path {
            guard let page = makePage(index) else { return }
            let direction: UIPageViewController.NavigationDirection = index >= currentIndex ? .forward : .reverse
            currentIndex = index
            setViewControllers([page], direction: direction, animated: false)
        }
        if let page = viewControllers?.first as? MediaPage {
            page.apply(turns: model.rotation(for: page.item), actualSize: model.actualSize, muted: settings.videoMuted)
        }
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? MediaPage else { return nil }
        return makePage(page.index - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? MediaPage else { return nil }
        return makePage(page.index + 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let page = viewControllers?.first as? MediaPage, let model else { return }
        currentIndex = page.index
        if model.viewerIndex != page.index {
            model.move(to: page.index)
            if let settings { MobileFeedback.play(.tick, settings: settings) }
        }
    }
}

struct PagerView: UIViewControllerRepresentable {
    @ObservedObject var model: LibraryModel
    @ObservedObject var settings: AppSettings

    func makeUIViewController(context: Context) -> PagerController {
        let controller = PagerController(
            transitionStyle: .scroll, navigationOrientation: .horizontal,
            options: [.interPageSpacing: 18]
        )
        controller.model = model
        controller.settings = settings
        return controller
    }

    func updateUIViewController(_ controller: PagerController, context: Context) {
        controller.loadViewIfNeeded()
        controller.sync()
    }
}

// MARK: - Viewer screen

struct MobileViewer: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var services: MobileServices
    @State private var infoItem: MediaItem?
    @State private var shareItem: MediaItem?

    private var item: MediaItem? {
        guard let index = model.viewerIndex, model.visible.indices.contains(index) else { return nil }
        return model.visible[index]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PagerView(model: model, settings: settings)
                .ignoresSafeArea()
            if let item, !model.interfaceHidden {
                VStack(spacing: 0) {
                    topBar(item)
                    Spacer()
                    bottomBar(item)
                }
                .transition(.opacity)
            }
            if let notice = model.notice {
                VStack {
                    Spacer()
                    Text(notice)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 110)
                }
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.interfaceHidden)
        .animation(.easeOut(duration: 0.15), value: model.notice)
        .statusBarHidden(model.interfaceHidden)
        .preferredColorScheme(.dark)
        .sheet(item: $infoItem) { InfoSheet(item: $0) }
        .sheet(item: $shareItem) { ActivityView(url: $0.url) }
    }

    private func topBar(_ item: MediaItem) -> some View {
        HStack(spacing: 12) {
            Button {
                model.closeViewer()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(item.folderName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let index = model.viewerIndex {
                Text("\((index + 1).formatted()) / \(model.visible.count.formatted())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private func bottomBar(_ item: MediaItem) -> some View {
        HStack(spacing: 6) {
            barButton(model.isFavorite(item) ? "heart.fill" : "heart", "Favorite", active: model.isFavorite(item)) {
                services.toggleFavorite(item)
            }
            if item.group != .video {
                barButton("1.magnifyingglass", "Original size", active: model.actualSize) { model.actualSize.toggle() }
                barButton("rotate.left", "Rotate left") { model.rotate(item, clockwise: false) }
                barButton("rotate.right", "Rotate right") { model.rotate(item, clockwise: true) }
            }
            barButton("info.circle", "Info") { infoItem = item }
            barButton("square.and.arrow.up", "Share") { shareItem = item }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 10)
        .id(model.favoritesVersion)
    }

    private func barButton(_ symbol: String, _ label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 40)
                .foregroundStyle(active ? MobileTheme.accent : Color.white)
        }
        .accessibilityLabel(label)
    }
}

struct InfoSheet: View {
    let item: MediaItem
    @State private var rows: [InfoRow] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(item.name).font(.headline).textSelection(.enabled)
                }
                Section {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.label.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(row.value).font(.subheadline).textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { rows = await MetadataReader.details(for: item) }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
