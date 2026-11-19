// Renders FlatGrid's own app icon (a 3×3 tile grid with one ember tile) into both asset catalogs.
// Run from the project root:  swift Scripts/make_icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func render(size: Int, fullBleed: Bool) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let alpha: CGImageAlphaInfo = fullBleed ? .noneSkipLast : .premultipliedLast
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue)!
    let plate: CGRect
    if fullBleed {
        plate = CGRect(x: 0, y: 0, width: s, height: s)
    } else {
        let inset = s * 0.0977
        plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    }
    let radius = fullBleed ? 0 : plate.width * 0.2237
    let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(platePath)
    ctx.setFillColor(CGColor(srgbRed: 0.075, green: 0.075, blue: 0.086, alpha: 1))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let colors = [CGColor(srgbRed: 0.16, green: 0.155, blue: 0.17, alpha: 1), CGColor(srgbRed: 0.055, green: 0.055, blue: 0.065, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: plate.midX, y: plate.maxY), end: CGPoint(x: plate.midX, y: plate.minY), options: [])
    ctx.restoreGState()

    let area = plate.insetBy(dx: plate.width * 0.2, dy: plate.width * 0.2)
    let unit = area.width / 3
    let gap = unit * 0.12
    let shades: [CGFloat] = [0.30, 0.42, 0.24, 0.48, 0, 0.34, 0.26, 0.38, 0.5]
    for index in 0..<9 {
        let row = index / 3, column = index % 3
        let rect = CGRect(x: area.minX + CGFloat(column) * unit + gap / 2,
                          y: area.maxY - CGFloat(row + 1) * unit + gap / 2,
                          width: unit - gap, height: unit - gap)
        let corner = unit * 0.17
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
        if index == 4 {
            ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.42, blue: 0.21, alpha: 1))
        } else {
            ctx.setFillColor(CGColor(gray: 1, alpha: shades[index]))
        }
        ctx.fillPath()
    }
    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let macDir = "Mac/Assets.xcassets/AppIcon.appiconset"
var macImages: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)@\(scale)x.png"
    write(render(size: points * scale, fullBleed: false), to: "\(macDir)/\(name)")
    macImages.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let macJSON: [String: Any] = ["images": macImages, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: macJSON, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: "\(macDir)/Contents.json"))

let iosDir = "iOS/Assets.xcassets/AppIcon.appiconset"
write(render(size: 1024, fullBleed: true), to: "\(iosDir)/icon_1024.png")
let iosJSON: [String: Any] = [
    "images": [["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon_1024.png"]],
    "info": ["author": "xcode", "version": 1],
]
try! JSONSerialization.data(withJSONObject: iosJSON, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: "\(iosDir)/Contents.json"))

let catalogInfo = try! JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted])
try! catalogInfo.write(to: URL(fileURLWithPath: "Mac/Assets.xcassets/Contents.json"))
try! catalogInfo.write(to: URL(fileURLWithPath: "iOS/Assets.xcassets/Contents.json"))
print("icons written")
