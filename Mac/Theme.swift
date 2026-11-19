import AppKit
import SwiftUI

/// FlatGrid's own look: warm neutral canvas, one ember accent.
enum Theme {
    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let nsAccent = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.21, alpha: 1)
    static let nsCanvas = dynamic(
        dark: NSColor(srgbRed: 0.055, green: 0.055, blue: 0.063, alpha: 1),
        light: NSColor(srgbRed: 0.957, green: 0.953, blue: 0.941, alpha: 1)
    )
    static let nsTile = dynamic(
        dark: NSColor(white: 1, alpha: 0.055),
        light: NSColor(white: 0, alpha: 0.05)
    )
    static let nsBar = dynamic(
        dark: NSColor(srgbRed: 0.085, green: 0.085, blue: 0.095, alpha: 1),
        light: NSColor(srgbRed: 0.985, green: 0.982, blue: 0.972, alpha: 1)
    )
    static let nsHairline = dynamic(
        dark: NSColor(white: 1, alpha: 0.09),
        light: NSColor(white: 0, alpha: 0.1)
    )
    static let nsField = dynamic(
        dark: NSColor(white: 1, alpha: 0.07),
        light: NSColor(white: 0, alpha: 0.06)
    )

    static let accent = Color(nsColor: nsAccent)
    static let canvas = Color(nsColor: nsCanvas)
    static let bar = Color(nsColor: nsBar)
    static let hairline = Color(nsColor: nsHairline)
    static let field = Color(nsColor: nsField)
}
