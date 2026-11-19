# FlatGrid — Architecture

A folder-flattening media browser. One Xcode project, two app targets (macOS 14+, iOS 17+),
one shared core. No third-party dependencies, no network code.

## Modules

| Folder | Target(s) | Contents |
|---|---|---|
| `Shared/` | Mac + iOS | `MediaTypes` (extension → group), `MediaItem`, `FolderScanner`, `LibraryQuery` (filter/sort/search, pure), `MetadataReader`, `FavoritesStore`, `AppSettings`, `LibraryModel`, `ThumbnailPipeline`, `ImageLoader`, `AppPaths`, `Fixtures` (sample/test media generator) |
| `Mac/` | Mac | AppKit window and menu bar, SwiftUI content (`RootView`, bars, settings, info panel), AppKit grid (`GridViewController`, layer tiles), AppKit viewer (zoom scroll view, `AVPlayerView`), key handling, synthesised `Sounds`, `Verify` |
| `iOS/` | iOS | SwiftUI shell, `UICollectionView` grid, paging viewer, Files folder picker |
| `Config/` | — | entitlements (sandbox, read-only user-selected files, app-scoped bookmarks) |

## Scan / enumeration

`FolderScanner.scan(root:)` walks one root with `FileManager.enumerator(at:includingPropertiesForKeys:)`,
prefetching type, dates, size and Finder tags in the same pass. Hidden files and package contents are
skipped; symlinked directories are not followed. The extension is checked before any attribute is
read, so non-media files cost almost nothing. Each root scans on a background task; results are merged,
de-duplicated by path and handed to `LibraryQuery`, a pure function that filters (type groups,
favorites, search) and sorts off the main thread. A generation counter drops stale results.

Search matches a pre-folded key (filename + Finder tags) plus a metadata string (EXIF/TIFF/IPTC/PNG/PDF
fields already in the file) built lazily in the background. Nothing is analysed or generated.

## Thumbnail pipeline (how 10,000+ items stay smooth)

- **Grid**: on the Mac, a plain scroll view whose visible tiles are recycled `CALayer`s placed
  arithmetically from the item index, so layout cost is O(visible), independent of library size.
  (`NSCollectionView` was measured first and spent ~0.6 ms per recycled cell.) A tile's `contents`
  is a pre-decoded `CGImage`; nothing is drawn on the main thread. iPhone uses `UICollectionView`.
- **Display format**: thumbnails are redrawn into 8-bit BGRA (sRGB or Display P3) on worker threads,
  so Core Animation takes them as-is instead of converting each one on the main thread.
- **Three tiers**: memory (`NSCache`, cost-limited) → disk (JPEG/PNG, keyed by SHA-256 of
  path + mtime + size, per size bucket) → generate.
- **Generation**: `CGImageSource` thumbnail decode for images/RAW (embedded preview for RAW when
  present), `QLThumbnailGenerator` for video, layered files and anything ImageIO refuses.
- **Scheduling**: bounded worker pool, LIFO so the cells on screen now are served first, a separate
  low-priority lane for prefetch, cancellation when a cell scrolls away, de-duplication of in-flight keys.
- **Size buckets** (128/256/512/1024 px): changing density only re-requests when the bucket changes.

## Viewer

Shows the cached thumbnail immediately, then a screen-sized decode, then the full-resolution decode
only when zoomed past it (Z = 1 image pixel per device pixel). Video plays inline via AVFoundation.
Rotation is view state only.

## Where the app's data lives

Only inside the app's own container:

- `Application Support/FlatGrid/roots.json` — added folders as read-only security-scoped bookmarks
- `Application Support/FlatGrid/favorites.json` — favorites, each keyed by a file bookmark
- `Caches/FlatGrid/Thumbnails/` — thumbnail cache (safe to delete)
- `UserDefaults` — settings

User files are opened read-only. On macOS the sandbox entitlement is `files.user-selected.read-only`,
so the OS itself refuses writes to anything the user adds. There is no network entitlement.
