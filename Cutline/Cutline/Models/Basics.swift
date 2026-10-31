import CoreImage
import SwiftUI
import UIKit

/// Codable sRGB color.
struct RGBAColor: Codable, Hashable {
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
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        if !uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0
            uiColor.getWhite(&white, alpha: &alpha)
            red = white
            green = white
            blue = white
        }
        r = min(max(Double(red), 0), 1)
        g = min(max(Double(green), 0), 1)
        b = min(max(Double(blue), 0), 1)
        a = min(max(Double(alpha), 0), 1)
    }

    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(uiColor: uiColor) }
    var ciColor: CIColor { CIColor(red: r, green: g, blue: b, alpha: a) }

    /// Hue in 0...1.
    var hue: Double {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, alpha: CGFloat = 0
        uiColor.getHue(&h, saturation: &s, brightness: &v, alpha: &alpha)
        return Double(h)
    }

    static let white = RGBAColor(1, 1, 1)
    static let black = RGBAColor(0, 0, 0)
    static let yellow = RGBAColor(hex: 0xFFD60A)
    static let green = RGBAColor(0, 1, 0)
    static let red = RGBAColor(hex: 0xFF453A)
    static let blue = RGBAColor(hex: 0x0A84FF)

    static let palette: [RGBAColor] = [
        .white, .black, RGBAColor(hex: 0x8E8E93), .red, RGBAColor(hex: 0xFF9F0A), .yellow,
        RGBAColor(hex: 0x32D74B), RGBAColor(hex: 0x64D2FF), .blue, RGBAColor(hex: 0xBF5AF2), RGBAColor(hex: 0xFF375F)
    ]
}

/// System fonts available to text and captions.
enum FontChoice: String, Codable, CaseIterable, Identifiable {
    case sanFrancisco, sfRounded, sfMono, newYork, helveticaNeue, avenirNext, futura, georgia,
         markerFelt, noteworthy, chalkboard, courierNew, baskerville, didot, americanTypewriter, gillSans, optima, bradleyHand

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sanFrancisco: return "San Francisco"
        case .sfRounded: return "SF Rounded"
        case .sfMono: return "SF Mono"
        case .newYork: return "New York"
        case .helveticaNeue: return "Helvetica Neue"
        case .avenirNext: return "Avenir Next"
        case .futura: return "Futura"
        case .georgia: return "Georgia"
        case .markerFelt: return "Marker Felt"
        case .noteworthy: return "Noteworthy"
        case .chalkboard: return "Chalkboard SE"
        case .courierNew: return "Courier New"
        case .baskerville: return "Baskerville"
        case .didot: return "Didot"
        case .americanTypewriter: return "American Typewriter"
        case .gillSans: return "Gill Sans"
        case .optima: return "Optima"
        case .bradleyHand: return "Bradley Hand"
        }
    }

    private var familyName: String? {
        switch self {
        case .sanFrancisco, .sfRounded, .sfMono, .newYork: return nil
        case .chalkboard: return "Chalkboard SE"
        default: return displayName
        }
    }

    private static let cache = NSCache<NSString, UIFont>()

    func uiFont(size: CGFloat, bold: Bool) -> UIFont {
        let key = "\(rawValue)|\(size)|\(bold)" as NSString
        if let cached = FontChoice.cache.object(forKey: key) { return cached }
        let weight: UIFont.Weight = bold ? .heavy : .regular
        var font: UIFont
        switch self {
        case .sanFrancisco:
            font = .systemFont(ofSize: size, weight: weight)
        case .sfRounded:
            font = FontChoice.designed(.rounded, size: size, weight: weight)
        case .sfMono:
            font = .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        case .newYork:
            font = FontChoice.designed(.serif, size: size, weight: bold ? .bold : .regular)
        default:
            font = UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: familyName ?? "Helvetica Neue"]), size: size)
            if bold, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) {
                font = UIFont(descriptor: descriptor, size: size)
            }
        }
        FontChoice.cache.setObject(font, forKey: key)
        return font
    }

    private static func designed(_ design: UIFontDescriptor.SystemDesign, size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// Position, scale, rotation and opacity of a layer. Positions are offsets
/// from the canvas center as fractions of the canvas size (y grows down).
struct TransformValues: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var scale: Double = 1
    var rotation: Double = 0
    var opacity: Double = 1

    static let identity = TransformValues()

    static func lerp(_ a: TransformValues, _ b: TransformValues, _ t: Double) -> TransformValues {
        TransformValues(x: a.x + (b.x - a.x) * t,
                        y: a.y + (b.y - a.y) * t,
                        scale: a.scale + (b.scale - a.scale) * t,
                        rotation: a.rotation + (b.rotation - a.rotation) * t,
                        opacity: a.opacity + (b.opacity - a.opacity) * t)
    }
}

enum Easing: String, Codable, CaseIterable, Identifiable {
    case linear, easeIn, easeOut, easeInOut, bounce

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        case .easeInOut: return "Smooth"
        case .bounce: return "Bounce"
        }
    }

    func apply(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        switch self {
        case .linear:
            return t
        case .easeIn:
            return t * t * t
        case .easeOut:
            let u = 1 - t
            return 1 - u * u * u
        case .easeInOut:
            return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .bounce:
            let c1 = 1.70158
            let c3 = c1 + 1
            return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        }
    }
}

/// A transform keyframe. `time` is relative to the item's start on the timeline.
struct Keyframe: Codable, Identifiable, Equatable {
    var id = UUID()
    var time: Double
    var values: TransformValues
    var easing: Easing = .easeInOut
}

enum KeyframeMath {
    static func value(base: TransformValues, keyframes: [Keyframe], at time: Double) -> TransformValues {
        guard !keyframes.isEmpty else { return base }
        let sorted = keyframes.sorted { $0.time < $1.time }
        guard let first = sorted.first, let last = sorted.last else { return base }
        if time <= first.time { return first.values }
        if time >= last.time { return last.values }
        for index in 0..<(sorted.count - 1) {
            let a = sorted[index]
            let b = sorted[index + 1]
            if time >= a.time && time <= b.time {
                let span = max(b.time - a.time, 0.000_1)
                return TransformValues.lerp(a.values, b.values, a.easing.apply((time - a.time) / span))
            }
        }
        return last.values
    }
}

extension Double {
    func clamped(_ range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

enum TimeFormat {
    static func string(_ seconds: Double, showFraction: Bool = true) -> String {
        let value = max(seconds, 0)
        let minutes = Int(value) / 60
        let secs = Int(value) % 60
        if showFraction {
            let tenths = Int((value - floor(value)) * 10)
            return String(format: "%d:%02d.%d", minutes, secs, tenths)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
