import SwiftUI
import UIKit

/// A plain, Codable sRGB color.
struct RGBA: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }

    init(uiColor: UIColor) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        if uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            r = Double(red)
            g = Double(green)
            b = Double(blue)
            a = Double(alpha)
        } else {
            var white: CGFloat = 0.5
            if uiColor.getWhite(&white, alpha: &alpha) {
                r = Double(white)
                g = Double(white)
                b = Double(white)
                a = Double(alpha)
            } else {
                r = 0.5
                g = 0.5
                b = 0.5
                a = 1
            }
        }
        r = min(max(r, 0), 1)
        g = min(max(g, 0), 1)
        b = min(max(b, 0), 1)
        a = min(max(a, 0), 1)
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    var cgColor: CGColor {
        uiColor.cgColor
    }

    var color: Color {
        Color(uiColor: uiColor)
    }

    func withAlpha(_ alpha: Double) -> RGBA {
        RGBA(r, g, b, alpha)
    }

    var luminance: Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

/// A color reference stored on objects. `themeForeground` and `sticky` resolve
/// against the board's current theme so they adapt when the theme changes.
enum PaintColor: Codable, Hashable {
    case clear
    case themeForeground
    case sticky(Int)
    case custom(RGBA)

    func rgba(in theme: Theme) -> RGBA? {
        switch self {
        case .clear:
            return nil
        case .themeForeground:
            return theme.foreground
        case .sticky(let index):
            let palette = theme.stickyPalette
            guard !palette.isEmpty else { return theme.foreground }
            let count = palette.count
            return palette[((index % count) + count) % count]
        case .custom(let rgba):
            return rgba
        }
    }

    func uiColor(in theme: Theme) -> UIColor? {
        rgba(in: theme)?.uiColor
    }

    var isThemeAdaptive: Bool {
        switch self {
        case .themeForeground, .sticky:
            return true
        case .clear, .custom:
            return false
        }
    }
}

enum Palette {
    static let white = RGBA(hex: 0xF5F5F7)
    static let gray = RGBA(hex: 0x8E8E93)
    static let black = RGBA(hex: 0x1C1C1E)
    static let red = RGBA(hex: 0xFF453A)
    static let orange = RGBA(hex: 0xFF9F0A)
    static let yellow = RGBA(hex: 0xFFD60A)
    static let green = RGBA(hex: 0x32D74B)
    static let teal = RGBA(hex: 0x64D2FF)
    static let blue = RGBA(hex: 0x0A84FF)
    static let purple = RGBA(hex: 0xBF5AF2)
    static let pink = RGBA(hex: 0xFF375F)
    static let brown = RGBA(hex: 0xAC8E68)

    static let colors: [RGBA] = [white, gray, black, red, orange, yellow, green, teal, blue, purple, pink, brown]
}
