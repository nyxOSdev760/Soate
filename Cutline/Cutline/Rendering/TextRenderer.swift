import CoreImage
import UIKit

/// Draws titles, captions, stickers and shapes into cached images for the
/// compositor. UIGraphicsImageRenderer is thread-safe, so this runs on the
/// compositor's queue.
final class TextRenderer: @unchecked Sendable {
    static let shared = TextRenderer()

    private let cache = NSCache<NSString, CIImage>()

    init() {
        cache.countLimit = 300
    }

    // MARK: Titles

    /// Renders a title. `visibleCharacters` supports the typewriter animation.
    func image(for item: TextItem, canvas: CGSize, visibleCharacters: Int?) -> CIImage? {
        let text = visibleCharacters.map { String(item.text.prefix($0)) } ?? item.text
        guard !text.isEmpty else { return nil }
        let key = "title|\(text)|\(styleKey(item.style))|\(Int(canvas.width))x\(Int(canvas.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let fontSize = CGFloat(item.style.size) * canvas.height
        let attributed = attributedString(text, style: item.style, fontSize: fontSize, highlightRange: nil, highlightColor: nil)
        let image = render(attributed, style: item.style, fontSize: fontSize, maxWidth: canvas.width * 0.9)
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    // MARK: Captions

    func captionImage(line: CaptionLine, track: CaptionTrack, highlightedWord: Int?, canvas: CGSize) -> CIImage? {
        guard !line.words.isEmpty else { return nil }
        let key = "caption|\(line.id)|\(line.text)|\(track.style.rawValue)|\(track.font.rawValue)|\(highlightedWord ?? -1)|\(Int(canvas.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let style = captionStyle(for: track)
        let fontSize = CGFloat(style.size) * canvas.height
        var text = line.text
        if track.style == .boldCenter {
            text = text.uppercased()
        }
        var highlight: NSRange?
        if track.style == .karaoke, let index = highlightedWord, index < line.words.count {
            var location = 0
            for word in line.words.prefix(index) {
                location += (word.text as NSString).length + 1
            }
            highlight = NSRange(location: location, length: (line.words[index].text as NSString).length)
        }
        let attributed = attributedString(text, style: style, fontSize: fontSize, highlightRange: highlight, highlightColor: .yellow)
        let image = render(attributed, style: style, fontSize: fontSize, maxWidth: canvas.width * 0.86)
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    func captionStyle(for track: CaptionTrack) -> TextStyle {
        switch track.style {
        case .boldCenter:
            return TextStyle(font: track.font, isBold: true, size: 0.05, color: .white, outlineEnabled: true,
                             outlineColor: .black, shadowEnabled: true, backgroundEnabled: false, alignment: .center)
        case .karaoke:
            return TextStyle(font: track.font, isBold: true, size: 0.045, color: .white, outlineEnabled: true,
                             outlineColor: .black, shadowEnabled: true, backgroundEnabled: false, alignment: .center)
        case .minimalBottom:
            return TextStyle(font: track.font, isBold: false, size: 0.03, color: .white, outlineEnabled: false,
                             outlineColor: .black, shadowEnabled: false, backgroundEnabled: true,
                             backgroundColor: RGBAColor(0, 0, 0, 0.55), alignment: .center)
        }
    }

    /// Vertical center of caption lines as a fraction of the canvas height from the top.
    static func captionCenterY(_ style: CaptionStyle) -> Double {
        switch style {
        case .boldCenter: return 0.6
        case .karaoke: return 0.72
        case .minimalBottom: return 0.86
        }
    }

    // MARK: Stickers and shapes

    func stickerImage(_ emoji: String, pixelWidth: CGFloat) -> CIImage? {
        let width = max(16, min(pixelWidth, 2048).rounded())
        let key = "sticker|\(emoji)|\(Int(width))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let size = CGSize(width: width, height: width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let font = UIFont.systemFont(ofSize: width * 0.82)
            let string = NSAttributedString(string: emoji, attributes: [.font: font])
            let bounds = string.boundingRect(with: size, options: [.usesLineFragmentOrigin], context: nil)
            string.draw(at: CGPoint(x: (width - bounds.width) / 2, y: (width - bounds.height) / 2))
        }
        guard let cgImage = rendered.cgImage else { return nil }
        let image = CIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }

    func shapeImage(_ shape: OverlayShape, color: RGBAColor, pixelWidth: CGFloat) -> CIImage? {
        let width = max(16, min(pixelWidth, 2048).rounded())
        let height = shape == .arrow ? (width * 0.5).rounded() : width
        let key = "shape|\(shape.rawValue)|\(color.r),\(color.g),\(color.b),\(color.a)|\(Int(width))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            color.uiColor.setFill()
            TextRenderer.path(for: shape, in: rect).fill()
        }
        guard let cgImage = rendered.cgImage else { return nil }
        let image = CIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }

    static func path(for shape: OverlayShape, in rect: CGRect) -> UIBezierPath {
        switch shape {
        case .rectangle:
            return UIBezierPath(rect: rect)
        case .roundedRectangle:
            return UIBezierPath(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.18)
        case .circle:
            return UIBezierPath(ovalIn: rect)
        case .star:
            let path = UIBezierPath()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outer = min(rect.width, rect.height) / 2
            let inner = outer * 0.42
            for index in 0..<10 {
                let radius = index % 2 == 0 ? outer : inner
                let angle = Double(index) * Double.pi / 5 - Double.pi / 2
                let point = CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.close()
            return path
        case .heart:
            let path = UIBezierPath()
            let w = rect.width
            let h = rect.height
            path.move(to: CGPoint(x: w * 0.5, y: h * 0.95))
            path.addCurve(to: CGPoint(x: 0, y: h * 0.32), controlPoint1: CGPoint(x: w * 0.2, y: h * 0.75), controlPoint2: CGPoint(x: 0, y: h * 0.55))
            path.addArc(withCenter: CGPoint(x: w * 0.25, y: h * 0.3), radius: w * 0.25, startAngle: .pi, endAngle: 0, clockwise: true)
            path.addArc(withCenter: CGPoint(x: w * 0.75, y: h * 0.3), radius: w * 0.25, startAngle: .pi, endAngle: 0, clockwise: true)
            path.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.95), controlPoint1: CGPoint(x: w, y: h * 0.55), controlPoint2: CGPoint(x: w * 0.8, y: h * 0.75))
            path.close()
            return path
        case .arrow:
            let path = UIBezierPath()
            let h = rect.height
            let w = rect.width
            path.move(to: CGPoint(x: 0, y: h * 0.35))
            path.addLine(to: CGPoint(x: w * 0.62, y: h * 0.35))
            path.addLine(to: CGPoint(x: w * 0.62, y: 0))
            path.addLine(to: CGPoint(x: w, y: h * 0.5))
            path.addLine(to: CGPoint(x: w * 0.62, y: h))
            path.addLine(to: CGPoint(x: w * 0.62, y: h * 0.65))
            path.addLine(to: CGPoint(x: 0, y: h * 0.65))
            path.close()
            return path
        }
    }

    // MARK: Drawing

    private func styleKey(_ style: TextStyle) -> String {
        "\(style.font.rawValue)|\(style.isBold)|\(style.size)|\(style.color)|\(style.outlineEnabled)|\(style.outlineColor)|\(style.shadowEnabled)|\(style.backgroundEnabled)|\(style.backgroundColor)|\(style.alignment.rawValue)"
    }

    private func attributedString(_ text: String, style: TextStyle, fontSize: CGFloat,
                                  highlightRange: NSRange?, highlightColor: UIColor?) -> NSMutableAttributedString {
        let paragraph = NSMutableParagraphStyle()
        switch style.alignment {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: style.font.uiFont(size: max(fontSize, 4), bold: style.isBold),
            .foregroundColor: style.color.uiColor,
            .paragraphStyle: paragraph
        ])
        if let highlightRange, let highlightColor, NSMaxRange(highlightRange) <= attributed.length {
            attributed.addAttribute(.foregroundColor, value: highlightColor, range: highlightRange)
        }
        return attributed
    }

    private func render(_ attributed: NSMutableAttributedString, style: TextStyle, fontSize: CGFloat, maxWidth: CGFloat) -> CIImage? {
        let textBounds = attributed.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let padding = style.backgroundEnabled ? fontSize * 0.45 : fontSize * 0.25
        let size = CGSize(width: ceil(textBounds.width + padding * 2), height: ceil(textBounds.height + padding * 2))
        guard size.width > 1, size.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let textRect = CGRect(x: padding, y: padding, width: ceil(textBounds.width), height: ceil(textBounds.height))
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            if style.backgroundEnabled {
                style.backgroundColor.uiColor.setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: fontSize * 0.3).fill()
            }
            if style.shadowEnabled {
                context.cgContext.setShadow(offset: CGSize(width: 0, height: fontSize * 0.06), blur: fontSize * 0.25,
                                            color: UIColor.black.withAlphaComponent(0.6).cgColor)
            }
            if style.outlineEnabled {
                let outline = NSMutableAttributedString(attributedString: attributed)
                outline.addAttributes([
                    .strokeColor: style.outlineColor.uiColor,
                    .strokeWidth: 16
                ], range: NSRange(location: 0, length: outline.length))
                outline.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            }
            attributed.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        guard let cgImage = rendered.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
