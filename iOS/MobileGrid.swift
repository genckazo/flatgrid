import SwiftUI
import UIKit

final class ThumbCell: UICollectionViewCell {
    static let reuseID = "ThumbCell"

    private let imageView = UIImageView()
    private let favoriteDot = UIView()
    private let videoGlyph = UIImageView(image: UIImage(systemName: "play.fill"))
    private let label = UILabel()
    private var token: ThumbnailPipeline.Token?
    private(set) var path: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor.secondarySystemBackground
        contentView.clipsToBounds = true

        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)

        label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.frame = contentView.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.isHidden = true
        contentView.addSubview(label)

        favoriteDot.backgroundColor = MobileTheme.uiAccent
        favoriteDot.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        favoriteDot.layer.borderWidth = 1.5
        favoriteDot.isHidden = true
        contentView.addSubview(favoriteDot)

        videoGlyph.tintColor = .white
        videoGlyph.contentMode = .scaleAspectFit
        videoGlyph.layer.shadowColor = UIColor.black.cgColor
        videoGlyph.layer.shadowOpacity = 0.6
        videoGlyph.layer.shadowRadius = 2
        videoGlyph.layer.shadowOffset = .zero
        videoGlyph.isHidden = true
        contentView.addSubview(videoGlyph)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = contentView.bounds.width
        let dot = min(12, max(7, side / 11))
        let inset = max(4, side / 20)
        favoriteDot.frame = CGRect(x: side - inset - dot, y: inset, width: dot, height: dot)
        favoriteDot.layer.cornerRadius = dot / 2
        let glyph = min(15, max(9, side / 9))
        videoGlyph.frame = CGRect(x: inset, y: contentView.bounds.height - inset - glyph, width: glyph, height: glyph)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        ThumbnailPipeline.shared.cancel(token)
        token = nil
        path = nil
        imageView.image = nil
        label.isHidden = true
    }

    func configure(item: MediaItem, bucket: Int, crop: Bool, favorite: Bool) {
        let pipeline = ThumbnailPipeline.shared
        pipeline.cancel(token)
        token = nil
        path = item.path
        label.isHidden = true
        imageView.contentMode = crop ? .scaleAspectFill : .scaleAspectFit
        let small = contentView.bounds.width < 40
        favoriteDot.isHidden = !favorite || small
        videoGlyph.isHidden = item.group != .video || small

        if let ready = pipeline.cached(item, bucket: bucket) {
            imageView.image = UIImage(cgImage: ready)
            return
        }
        let standIn = pipeline.bestCached(item, preferring: bucket)
        imageView.image = standIn.map { UIImage(cgImage: $0) }
        let expectedPath = item.path
        let fallback = item.fileExtension.uppercased()
        token = pipeline.request(item, bucket: bucket) { [weak self] image in
            guard let self, self.path == expectedPath else { return }
            self.token = nil
            if let image {
                self.imageView.image = UIImage(cgImage: image)
            } else if standIn == nil {
                self.label.text = fallback
                self.label.isHidden = false
            }
        }
    }

    func setFavorite(_ favorite: Bool) {
        favoriteDot.isHidden = !favorite || contentView.bounds.width < 40
    }

    func setCrop(_ crop: Bool) {
        imageView.contentMode = crop ? .scaleAspectFill : .scaleAspectFit
    }
}

/// The phone grid: one continuous collection of every item, a fixed number of columns.
final class MobileGridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    private let layout = UICollectionViewFlowLayout()
    private(set) lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

    private(set) var items: [MediaItem] = []
    private(set) var columns = 4
    private var crop = false
    private var bucket = 256
    private var laidOutWidth: CGFloat = 0
    private var prefetchTokens: [String: ThumbnailPipeline.Token] = [:]

    var isFavorite: (MediaItem) -> Bool = { _ in false }
    var onOpen: ((Int) -> Void)?
    var onColumnsChange: ((Int) -> Void)?
    var menuProvider: ((Int) -> UIMenu?)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.register(ThumbCell.self, forCellWithReuseIdentifier: ThumbCell.reuseID)
        view.addSubview(collectionView)
        collectionView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = collectionView.bounds.inset(by: collectionView.safeAreaInsets).width
        if abs(width - laidOutWidth) > 0.5 {
            laidOutWidth = width
            applyItemSize()
        }
    }

    private func applyItemSize() {
        guard laidOutWidth > 0 else { return }
        let spacing = layout.minimumInteritemSpacing
        let side = floor((laidOutWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        layout.itemSize = CGSize(width: max(8, side), height: max(8, side))
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        let wanted = ThumbnailPipeline.bucket(forPixelSide: side * scale)
        if wanted != bucket {
            bucket = wanted
            reconfigureVisibleCells()
        }
    }

    private func reconfigureVisibleCells() {
        for case let cell as ThumbCell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell), indexPath.item < items.count else { continue }
            let item = items[indexPath.item]
            cell.configure(item: item, bucket: bucket, crop: crop, favorite: isFavorite(item))
        }
    }

    // MARK: Updates from the model

    func setItems(_ newItems: [MediaItem], resetScroll: Bool) {
        for token in prefetchTokens.values { ThumbnailPipeline.shared.cancel(token) }
        prefetchTokens.removeAll()
        items = newItems
        collectionView.reloadData()
        if resetScroll, !newItems.isEmpty {
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
        }
    }

    func setColumns(_ newValue: Int, animated: Bool) {
        let clamped = min(max(newValue, 1), 12)
        guard clamped != columns else { return }
        columns = clamped
        guard isViewLoaded else { return }
        if animated {
            UIView.animate(withDuration: 0.22) {
                self.applyItemSize()
                self.collectionView.performBatchUpdates(nil)
            }
        } else {
            applyItemSize()
            layout.invalidateLayout()
        }
    }

    func setCrop(_ newValue: Bool) {
        guard newValue != crop else { return }
        crop = newValue
        for case let cell as ThumbCell in collectionView.visibleCells { cell.setCrop(crop) }
    }

    func refreshFavorites() {
        for case let cell as ThumbCell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell), indexPath.item < items.count else { continue }
            cell.setFavorite(isFavorite(items[indexPath.item]))
        }
    }

    func reveal(_ index: Int) {
        guard index < items.count else { return }
        let indexPath = IndexPath(item: index, section: 0)
        if !collectionView.indexPathsForVisibleItems.contains(indexPath) {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        }
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed else { return }
        if gesture.scale > 1.28, columns > 1 {
            onColumnsChange?(columns - 1)
            gesture.scale = 1
        } else if gesture.scale < 0.78, columns < 12 {
            onColumnsChange?(columns + 1)
            gesture.scale = 1
        }
    }

    // MARK: Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ThumbCell.reuseID, for: indexPath)
        guard let thumb = cell as? ThumbCell, indexPath.item < items.count else { return cell }
        let item = items[indexPath.item]
        thumb.configure(item: item, bucket: bucket, crop: crop, favorite: isFavorite(item))
        return thumb
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        onOpen?(indexPath.item)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let index = indexPaths.first?.item, index < items.count else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menuProvider?(index)
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let pipeline = ThumbnailPipeline.shared
        for indexPath in indexPaths where indexPath.item < items.count {
            let item = items[indexPath.item]
            guard prefetchTokens[item.path] == nil, pipeline.cached(item, bucket: bucket) == nil else { continue }
            let path = item.path
            prefetchTokens[path] = pipeline.request(item, bucket: bucket, lowPriority: true) { [weak self] _ in
                self?.prefetchTokens[path] = nil
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths where indexPath.item < items.count {
            if let token = prefetchTokens.removeValue(forKey: items[indexPath.item].path) {
                ThumbnailPipeline.shared.cancel(token)
            }
        }
    }
}

struct MobileGridView: UIViewControllerRepresentable {
    @ObservedObject var model: LibraryModel
    @ObservedObject var settings: AppSettings
    let services: MobileServices
    let onShare: (MediaItem) -> Void
    let onInfo: (MediaItem) -> Void

    final class Coordinator {
        var visibleVersion = -1
        var favoritesVersion = -1
        var sortMode: SortMode?
        var viewerWasOpen = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> MobileGridController {
        let controller = MobileGridController()
        let model = self.model
        let settings = self.settings
        let services = self.services
        let onShare = self.onShare
        let onInfo = self.onInfo
        controller.isFavorite = { model.isFavorite($0) }
        controller.onOpen = { index in
            MobileFeedback.play(.tick, settings: settings)
            model.interfaceHidden = false
            model.open(index)
        }
        controller.onColumnsChange = { columns in
            MobileFeedback.play(.tick, settings: settings)
            settings.columnsOnPhone = columns
        }
        controller.menuProvider = { index in
            guard model.visible.indices.contains(index) else { return nil }
            let item = model.visible[index]
            let favorite = model.isFavorite(item)
            return UIMenu(children: [
                UIAction(title: favorite ? "Remove from Favorites" : "Add to Favorites",
                         image: UIImage(systemName: favorite ? "heart.slash" : "heart")) { _ in services.toggleFavorite(item) },
                UIAction(title: "Get Info", image: UIImage(systemName: "info.circle")) { _ in onInfo(item) },
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in services.copy(item) },
                UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { _ in onShare(item) },
            ])
        }
        controller.setColumns(settings.columnsOnPhone, animated: false)
        return controller
    }

    func updateUIViewController(_ controller: MobileGridController, context: Context) {
        let coordinator = context.coordinator
        controller.loadViewIfNeeded()
        controller.setCrop(settings.cropThumbnails)
        controller.setColumns(settings.columnsOnPhone, animated: coordinator.visibleVersion >= 0)
        if coordinator.visibleVersion != model.visibleVersion {
            let sortChanged = coordinator.sortMode != nil && coordinator.sortMode != settings.sortMode
            coordinator.visibleVersion = model.visibleVersion
            coordinator.sortMode = settings.sortMode
            coordinator.favoritesVersion = model.favoritesVersion
            controller.setItems(model.visible, resetScroll: sortChanged)
        } else if coordinator.favoritesVersion != model.favoritesVersion {
            coordinator.favoritesVersion = model.favoritesVersion
            controller.refreshFavorites()
        }
        // When the viewer closes, make sure the item last looked at is on screen.
        let viewerOpen = model.viewerIndex != nil
        if coordinator.viewerWasOpen && !viewerOpen, let index = model.selectedIndex {
            controller.reveal(index)
        }
        coordinator.viewerWasOpen = viewerOpen
    }
}
