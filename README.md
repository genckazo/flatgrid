# FlatGrid

A media browser for macOS that flattens a folder tree into one grid.

Add a folder and FlatGrid looks through every subfolder inside it. Every image and video, at any
depth, shows up in one continuous scrolling grid. Nothing is imported, copied, moved or changed:
FlatGrid only reads your files.

- macOS 14 or later, Apple silicon
- Native Swift (SwiftUI + AppKit), no third-party dependencies
- No network access, no accounts, no analytics

> **Status: early release.** The automated self-check passes (see below), but the app has had
> little hands-on testing. Expect rough edges and please report them.

## What it does

- **One grid for a whole folder tree.** Multiple folders and external drives are supported.
- **Density from a few large previews to hundreds on screen**, with a thumbnail pipeline that stays
  smooth at 10,000+ items.
- **Viewer** with previous/next item, previous/next folder, 100% original size, view-only rotation
  and inline video.
- **Sort** by date created, date added, name, type, folder or random.
- **Filter** by type: images, videos, RAW, layered documents (layered is off by default).
- **Search** by filename, Finder tags and metadata already stored in the file. Nothing is analysed
  or generated.
- **Favorites** kept in the app's own data, keyed by file bookmark. Your files are never written to.
- **Settings** for light/dark theme, sounds, trackpad haptics, video autoplay and which file types show.

### Formats

| Group | Extensions |
|---|---|
| Image | JPG JPEG JPE JFIF PNG WebP AVIF HEIC HEIF TIF TIFF GIF BMP JP2 J2K J2C JPC JPF JPX |
| Video | MOV MP4 M4V |
| RAW | DNG RAW CR2 CR3 CRW NEF NRW ARW SR2 SRF RAF RW2 RWL ORF ORI PEF PTX SRW 3FR FFF IIQ MOS MRW ERF KDC DCR X3F NEFX, plus any RAW type macOS recognises |
| Layered | PDF PSD AI PROCREATE |

Whether a given file previews depends on macOS being able to decode it.

### Keyboard

| Key | Action |
|---|---|
| ← → | Previous / next item |
| ↑ ↓ | Move between rows in the grid |
| ⌘↑ ⌘↓ | Previous / next folder |
| Space | Open or close the selected item |
| Tab | Show or hide the interface |
| + − | Thumbnail size |
| 1 – 6 | Sort: date created, date added, name, type, folders, random |
| S | Search |
| F | Add or remove favorite |
| Z | Original size (100%) |
| R | Reveal in Finder |
| I | Get info |
| C | Copy |
| [ ] | Rotate left / right (view only) |
| ⌘, | Settings |

## Install

### Download

Get `FlatGrid-mac-arm64.zip` from the [Releases](../../releases) page, unzip it and move
`FlatGrid.app` to Applications.

**The app is not notarized by Apple.** It is signed only for local use, so macOS will block it the
first time. To open it:

1. Double-click the app once and dismiss the warning.
2. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.

If macOS says the app is damaged, clear the download flag and try again:

```bash
xattr -dr com.apple.quarantine /Applications/FlatGrid.app
```

Only do this for a copy you downloaded from this repository. If you would rather not trust a
prebuilt binary, build it yourself.

### Build from source

Requires Xcode 16 or later.

```bash
git clone <this repository>
cd flatgrid
./Scripts/build-release.sh
open dist/FlatGrid.app
```

## Privacy and safety

- The app is sandboxed with **read-only** access to the folders you add. macOS itself refuses any
  write to them.
- There is no network entitlement and no networking code.
- FlatGrid writes only inside its own container: settings, the list of added folders, favorites,
  and a thumbnail cache you can clear in Settings.

## Self-check

The app can test itself:

```bash
dist/FlatGrid.app/Contents/MacOS/FlatGrid --verify
```

It generates a fixture folder tree inside its own temporary directory and proves, among other
things, that scan counts match per type group, each sort order is correct, search finds a
Finder-tagged file, and every fixture file is byte-for-byte unchanged after a full scan, thumbnail,
favorite and search cycle. It then loads 10,000 images and reports scroll frame timing.

The latest output is in [docs/verify-output.txt](docs/verify-output.txt): 31 checks, all passing,
60 fps in every scroll pass on a 60 Hz display.

What that does **not** cover: real RAW files (the fixtures use stand-in bytes), external drives,
120 Hz displays, and anything that needs a person at the keyboard and trackpad.

## How it works

See [ARCHITECTURE.md](ARCHITECTURE.md).

## Known limitations

- Apple silicon only.
- "Get info" is an in-app panel, not Finder's Get Info window.
- Rotation is view-only and is not remembered after quitting.
- Because the app is not signed with a Developer ID, macOS may ask you to add your folders again
  after you replace the app with a newer build.
- The repository also contains an experimental iPhone target (`FlatGridMobile`). It is not part of
  the release and has only been tried in the simulator.

## License

[MIT](LICENSE)
