// Cuts a screen recording into a short FlatGrid promo: title card, two clips with captions, end card.
import AVFoundation
import AppKit
import QuartzCore

let src = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.removeItem(at: out)

let W: CGFloat = 1920, H: CGFloat = 1080
let intro = 2.6, outro = 3.4
// (source start, source end, caption)
let clips: [(Double, Double, String)] = [
    (0.3, 6.3, "Every folder, every subfolder. One grid."),
    (28.0, 37.3, "Open. Zoom. Favorite. Your files are never touched."),
]
// Where the app window sits in the 1920×1080 recording, and how it is placed in the ad.
let crop = CGRect(x: 552, y: 200, width: 1000, height: 750)
let scale: CGFloat = 1.24
let placed = CGRect(x: (W - crop.width * scale) / 2, y: 36, width: crop.width * scale, height: crop.height * scale)
let accent = CGColor(srgbRed: 1.0, green: 0.42, blue: 0.21, alpha: 1)

func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let asset = AVURLAsset(url: src)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { fatalError("no video") }
        let audio = try await asset.loadTracks(withMediaType: .audio).first

        let comp = AVMutableComposition()
        let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let aTrack = audio == nil ? nil : comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = intro
        var captionTimes: [(Double, Double, String)] = []
        for (start, end, text) in clips {
            let range = CMTimeRange(start: t(start), end: t(end))
            try vTrack.insertTimeRange(range, of: video, at: t(cursor))
            if let audio, let aTrack { try aTrack.insertTimeRange(range, of: audio, at: t(cursor)) }
            captionTimes.append((cursor, cursor + end - start, text))
            cursor += end - start
        }
        let clipsEnd = cursor
        let total = clipsEnd + outro
        // Pad the timeline so the title and end cards have time to show.
        vTrack.insertEmptyTimeRange(CMTimeRange(start: t(clipsEnd), duration: t(outro)))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: t(total))
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
        var transform = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        transform = transform.concatenating(CGAffineTransform(translationX: placed.minX, y: placed.minY))
        layerInstruction.setCropRectangle(crop, at: .zero)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: W, height: H)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.instructions = [instruction]

        // ---- overlays (top-left coordinates)
        let parent = CALayer()
        parent.frame = CGRect(x: 0, y: 0, width: W, height: H)
        parent.isGeometryFlipped = true
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)

        func fade(_ layer: CALayer, values: [Float], times: [Double]) {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = values
            animation.keyTimes = times.map { NSNumber(value: $0 / total) }
            animation.duration = total
            animation.beginTime = AVCoreAnimationBeginTimeAtZero
            animation.isRemovedOnCompletion = false
            animation.fillMode = .both
            layer.opacity = values[0]
            layer.add(animation, forKey: "fade")
        }
        // Text is drawn into a bitmap first: text layers do not render reliably in an offline export.
        func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, frame: CGRect, rounded: Bool = false) -> CALayer {
            var font = NSFont.systemFont(ofSize: size, weight: weight)
            if rounded, let descriptor = font.fontDescriptor.withDesign(.rounded), let roundedFont = NSFont(descriptor: descriptor, size: size) { font = roundedFont }
            let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .white])
            let pixels = 2
            let width = Int(frame.width) * pixels, height = Int(frame.height) * pixels
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.scaleBy(x: CGFloat(pixels), y: CGFloat(pixels))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let measured = attributed.size()
            attributed.draw(at: CGPoint(x: (frame.width - measured.width) / 2, y: (frame.height - measured.height) / 2))
            NSGraphicsContext.restoreGraphicsState()
            let layer = CALayer()
            layer.frame = frame
            layer.contents = context.makeImage()
            return layer
        }
        func glyph(side: CGFloat) -> CALayer {
            let host = CALayer()
            host.frame = CGRect(x: 0, y: 0, width: side, height: side)
            let unit = side / 3, gap = unit * 0.12
            let shades: [CGFloat] = [0.30, 0.42, 0.24, 0.48, 0, 0.34, 0.26, 0.38, 0.5]
            for index in 0..<9 {
                let tile = CALayer()
                tile.frame = CGRect(x: CGFloat(index % 3) * unit + gap / 2, y: CGFloat(index / 3) * unit + gap / 2, width: unit - gap, height: unit - gap)
                tile.cornerRadius = unit * 0.17
                tile.backgroundColor = index == 4 ? accent : CGColor(gray: 1, alpha: shades[index])
                host.addSublayer(tile)
            }
            return host
        }
        func card(title: String, lines: [(String, CGFloat, NSFont.Weight, CGColor)]) -> CALayer {
            let layer = CALayer()
            layer.frame = parent.frame
            layer.backgroundColor = CGColor(srgbRed: 0.055, green: 0.055, blue: 0.063, alpha: 1)
            let mark = glyph(side: 190)
            mark.frame.origin = CGPoint(x: (W - 190) / 2, y: 250)
            layer.addSublayer(mark)
            layer.addSublayer(text(title, size: 104, weight: .bold, color: CGColor(gray: 1, alpha: 1), frame: CGRect(x: 0, y: 480, width: W, height: 130), rounded: true))
            var y: CGFloat = 630
            for (string, size, weight, color) in lines {
                layer.addSublayer(text(string, size: size, weight: weight, color: color, frame: CGRect(x: 0, y: y, width: W, height: size * 1.5)))
                y += size * 1.75
            }
            return layer
        }

        // Hide the left of the top bar (the folder chip shows a folder name) while the grid clip plays.
        let chipCover = CALayer()
        chipCover.backgroundColor = CGColor(srgbRed: 0.985, green: 0.982, blue: 0.972, alpha: 1)
        chipCover.frame = CGRect(x: placed.minX + (640 - crop.minX) * scale, y: placed.minY + (213 - crop.minY) * scale, width: 500 * scale, height: 30 * scale)
        parent.addSublayer(chipCover)
        fade(chipCover, values: [0, 0, 1, 1, 0, 0], times: [0, captionTimes[0].0 - 0.01, captionTimes[0].0, captionTimes[0].1, captionTimes[0].1 + 0.01, total])

        for (start, end, string) in captionTimes {
            let caption = text(string, size: 40, weight: .semibold, color: CGColor(gray: 1, alpha: 0.95), frame: CGRect(x: 0, y: placed.maxY + 24, width: W, height: 60), rounded: true)
            parent.addSublayer(caption)
            fade(caption, values: [0, 0, 1, 1, 0, 0], times: [0, start + 0.1, start + 0.6, end - 0.5, end - 0.05, total])
        }

        let introCard = card(title: "FlatGrid", lines: [("Your whole folder tree, in one grid.", 44, .medium, CGColor(gray: 1, alpha: 0.72))])
        parent.addSublayer(introCard)
        fade(introCard, values: [1, 1, 0, 0], times: [0, intro - 0.45, intro, total])

        let outroCard = card(title: "FlatGrid", lines: [
            ("Free and open source for macOS", 44, .medium, CGColor(gray: 1, alpha: 0.8)),
            ("github.com/genckazo/flatgrid", 38, .semibold, accent),
            ("macOS 14+  ·  Apple silicon  ·  no network, no accounts", 26, .regular, CGColor(gray: 1, alpha: 0.5)),
        ])
        parent.addSublayer(outroCard)
        fade(outroCard, values: [0, 0, 1, 1], times: [0, clipsEnd - 0.2, clipsEnd + 0.35, total])

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPreset1920x1080) else { fatalError("no export session") }
        export.videoComposition = videoComposition
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.timeRange = CMTimeRange(start: .zero, duration: t(total))
        await export.export()
        print("status", export.status.rawValue, export.error?.localizedDescription ?? "ok", "duration", total)
    } catch {
        print("failed", error)
    }
    sem.signal()
}
sem.wait()
