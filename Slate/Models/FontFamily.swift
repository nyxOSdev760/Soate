import UIKit

/// System fonts available for text objects.
enum FontFamily: String, Codable, CaseIterable, Identifiable {
    case sanFrancisco
    case sfRounded
    case sfMono
    case newYork
    case helveticaNeue
    case georgia
    case avenirNext
    case markerFelt
    case noteworthy
    case chalkboardSE
    case bradleyHand
    case courierNew
    case futura
    case baskerville

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sanFrancisco: return "San Francisco"
        case .sfRounded: return "SF Rounded"
        case .sfMono: return "SF Mono"
        case .newYork: return "New York"
        case .helveticaNeue: return "Helvetica Neue"
        case .georgia: return "Georgia"
        case .avenirNext: return "Avenir Next"
        case .markerFelt: return "Marker Felt"
        case .noteworthy: return "Noteworthy"
        case .chalkboardSE: return "Chalkboard SE"
        case .bradleyHand: return "Bradley Hand"
        case .courierNew: return "Courier New"
        case .futura: return "Futura"
        case .baskerville: return "Baskerville"
        }
    }

    /// The installed font family name for non-system-design fonts.
    var familyName: String? {
        switch self {
        case .sanFrancisco, .sfRounded, .sfMono, .newYork: return nil
        case .helveticaNeue: return "Helvetica Neue"
        case .georgia: return "Georgia"
        case .avenirNext: return "Avenir Next"
        case .markerFelt: return "Marker Felt"
        case .noteworthy: return "Noteworthy"
        case .chalkboardSE: return "Chalkboard SE"
        case .bradleyHand: return "Bradley Hand"
        case .courierNew: return "Courier New"
        case .futura: return "Futura"
        case .baskerville: return "Baskerville"
        }
    }

    private static let cache = NSCache<NSString, UIFont>()

    func uiFont(size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        let clampedSize = min(max(size, 1), 2000)
        let key = "\(rawValue)|\(clampedSize)|\(bold)|\(italic)" as NSString
        if let cached = FontFamily.cache.object(forKey: key) {
            return cached
        }
        let font = makeFont(size: clampedSize, bold: bold, italic: italic)
        FontFamily.cache.setObject(font, forKey: key)
        return font
    }

    private func makeFont(size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
        let weight: UIFont.Weight = bold ? .bold : .regular
        var font: UIFont
        switch self {
        case .sanFrancisco:
            font = UIFont.systemFont(ofSize: size, weight: weight)
        case .sfRounded:
            font = FontFamily.designedSystemFont(.rounded, size: size, weight: weight)
        case .sfMono:
            font = UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .newYork:
            font = FontFamily.designedSystemFont(.serif, size: size, weight: weight)
        default:
            let descriptor = UIFontDescriptor(fontAttributes: [.family: familyName ?? "Helvetica Neue"])
            font = UIFont(descriptor: descriptor, size: size)
            if bold {
                font = FontFamily.applying(.traitBold, to: font)
            }
        }
        if italic {
            font = FontFamily.italicized(font)
        }
        return font
    }

    private static func designedSystemFont(_ design: UIFontDescriptor.SystemDesign,
                                           size: CGFloat,
                                           weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(design) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    private static func applying(_ trait: UIFontDescriptor.SymbolicTraits, to font: UIFont) -> UIFont {
        var traits = font.fontDescriptor.symbolicTraits
        traits.insert(trait)
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
        return font
    }

    private static func italicized(_ font: UIFont) -> UIFont {
        var traits = font.fontDescriptor.symbolicTraits
        traits.insert(.traitItalic)
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            let candidate = UIFont(descriptor: descriptor, size: font.pointSize)
            if candidate.fontDescriptor.symbolicTraits.contains(.traitItalic) {
                return candidate
            }
        }
        // Families without an italic face get a synthetic oblique.
        let skew = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
        return UIFont(descriptor: font.fontDescriptor.withMatrix(skew), size: font.pointSize)
    }
}
