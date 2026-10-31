import UIKit

/// Core Graphics renderer shared by the on-screen canvas, thumbnails and
/// export. All drawing happens in world coordinates; callers set up the
/// context transform.
final class CanvasRenderer {
    let imageStore: ImageStore

    private struct CachedPath {
        let width: CGFloat
        let height: CGFloat
        let count: Int
        let path: CGPath
    }

    private var pathCache: [UUID: CachedPath] = [:]

    init(imageStore: ImageStore = .shared) {
        self.imageStore = imageStore
    }

    // MARK: Background

    /// Fills `worldRect` with the theme background and draws the pattern.
    /// `scale` is the number of output points per world unit, used to keep
    /// pattern lines crisp and density readable at any zoom.
    func drawBackground(in ctx: CGContext,
                        worldRect: CGRect,
                        theme: Theme,
                        pattern: BackgroundPattern,
                        scale: CGFloat) {
        ctx.setFillColor(theme.background.cgColor)
        ctx.fill(worldRect)
        guard pattern != .none,
              scale > 0,
              worldRect.width.isFinite,
              worldRect.height.isFinite,
              worldRect.width > 0,
              worldRect.height > 0 else { return }

        var spacing: CGFloat = 32
        let minimumScreenSpacing: CGFloat = pattern == .dots ? 16 : 12
        while spacing * scale < minimumScreenSpacing {
            spacing *= 2
        }
        let startX = floor(worldRect.minX / spacing) * spacing
        let startY = floor(worldRect.minY / spacing) * spacing
        let columns = Int((worldRect.maxX - startX) / spacing) + 1
        let rows = Int((worldRect.maxY - startY) / spacing) + 1
        guard columns > 0, rows > 0, columns < 2_000, rows < 2_000 else { return }

        ctx.saveGState()
        switch pattern {
        case .dots:
            guard columns * rows < 60_000 else { break }
            let radius = 1.4 / scale
            let path = CGMutablePath()
            for row in 0..<rows {
                let y = startY + CGFloat(row) * spacing
                for column in 0..<columns {
                    let x = startX + CGFloat(column) * spacing
                    path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                }
            }
            ctx.addPath(path)
            ctx.setFillColor(theme.patternColor.cgColor)
            ctx.fillPath()
        case .grid:
            let minor = CGMutablePath()
            let major = CGMutablePath()
            let firstColumnIndex = Int((startX / spacing).rounded())
            for column in 0..<columns {
                let x = startX + CGFloat(column) * spacing
                let target = (firstColumnIndex + column) % 4 == 0 ? major : minor
                target.move(to: CGPoint(x: x, y: worldRect.minY))
                target.addLine(to: CGPoint(x: x, y: worldRect.maxY))
            }
            let firstRowIndex = Int((startY / spacing).rounded())
            for row in 0..<rows {
                let y = startY + CGFloat(row) * spacing
                let target = (firstRowIndex + row) % 4 == 0 ? major : minor
                target.move(to: CGPoint(x: worldRect.minX, y: y))
                target.addLine(to: CGPoint(x: worldRect.maxX, y: y))
            }
            ctx.setStrokeColor(theme.patternColor.cgColor)
            ctx.setLineWidth(0.75 / scale)
            ctx.addPath(minor)
            ctx.strokePath()
            ctx.setStrokeColor(theme.patternColor.withAlpha(min(1, theme.patternColor.a * 1.8)).cgColor)
            ctx.setLineWidth(1.1 / scale)
            ctx.addPath(major)
            ctx.strokePath()
        case .lines:
            let path = CGMutablePath()
            for row in 0..<rows {
                let y = startY + CGFloat(row) * spacing
                path.move(to: CGPoint(x: worldRect.minX, y: y))
                path.addLine(to: CGPoint(x: worldRect.maxX, y: y))
            }
            ctx.setStrokeColor(theme.patternColor.cgColor)
            ctx.setLineWidth(0.9 / scale)
            ctx.addPath(path)
            ctx.strokePath()
        case .none:
            break
        }
        ctx.restoreGState()
    }

    // MARK: Objects

    /// Draws objects in order. Objects outside `visibleRect` are skipped.
    func drawObjects(_ objects: [BoardObject],
                     in ctx: CGContext,
                     theme: Theme,
                     visibleRect: CGRect?) {
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        for object in objects {
            if let visibleRect, !object.boundingBox.intersects(visibleRect) {
                continue
            }
            draw(object, in: ctx, theme: theme)
        }
    }

    func draw(_ object: BoardObject, in ctx: CGContext, theme: Theme) {
        ctx.saveGState()
        let center = object.center
        ctx.translateBy(x: center.x, y: center.y)
        if object.rotation != 0 {
            ctx.rotate(by: CGFloat(object.rotation))
        }
        let rect = object.localRect
        switch object.content {
        case .text(let text):
            drawText(text, in: rect, theme: theme)
        case .image(let image):
            drawImage(image, in: rect, ctx: ctx)
        case .sticky(let sticky):
            drawSticky(sticky, in: rect, ctx: ctx, theme: theme)
        case .stroke(let stroke):
            drawStroke(stroke, id: object.id, size: object.frame.size, ctx: ctx, theme: theme)
        }
        ctx.restoreGState()
    }

    // MARK: Text

    private func drawText(_ text: TextContent, in rect: CGRect, theme: Theme) {
        let color = text.color.uiColor(in: theme) ?? theme.foreground.uiColor
        let attributed: NSAttributedString
        if text.text.isEmpty {
            var placeholder = text
            placeholder.text = "Text"
            attributed = TextMetrics.attributedString(for: placeholder, color: color.withAlphaComponent(0.35))
        } else {
            attributed = TextMetrics.attributedString(for: text, color: color)
        }
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    private func drawSticky(_ sticky: StickyContent, in rect: CGRect, ctx: CGContext, theme: Theme) {
        let fill = sticky.color.uiColor(in: theme) ?? theme.stickyPalette.first?.uiColor ?? UIColor.systemYellow
        let corner = min(6, rect.width * 0.05, rect.height * 0.05)

        ctx.addPath(CGPath(roundedRect: rect.offsetBy(dx: 0, dy: 3), cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.22).cgColor)
        ctx.fillPath()

        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.setFillColor(fill.cgColor)
        ctx.fillPath()

        let padding = min(14, rect.width * 0.08)
        let textRect = rect.insetBy(dx: padding, dy: padding)
        guard !sticky.text.isEmpty, textRect.width > 4, textRect.height > 4 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: FontFamily.sfRounded.uiFont(size: CGFloat(sticky.fontSize), bold: false),
            .foregroundColor: theme.stickyText.uiColor,
            .paragraphStyle: paragraph
        ]
        ctx.saveGState()
        ctx.clip(to: rect)
        NSAttributedString(string: sticky.text, attributes: attributes)
            .draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        ctx.restoreGState()
    }

    // MARK: Images

    private func drawImage(_ image: ImageContent, in rect: CGRect, ctx: CGContext) {
        if let uiImage = imageStore.image(for: image.imageID) {
            uiImage.draw(in: rect, blendMode: .normal, alpha: CGFloat(min(max(image.opacity, 0), 1)))
            return
        }
        ctx.setFillColor(UIColor.gray.withAlphaComponent(0.25).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(UIColor.gray.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(rect)
        ctx.move(to: CGPoint(x: rect.minX, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        ctx.strokePath()
    }

    // MARK: Freehand

    static func pressureFactor(_ pressure: Double) -> CGFloat {
        CGFloat(0.35 + 1.1 * min(max(pressure, 0), 1))
    }

    private func drawStroke(_ stroke: StrokeContent, id: UUID, size: CGSize, ctx: CGContext, theme: Theme) {
        guard var color = stroke.color.uiColor(in: theme), !stroke.points.isEmpty else { return }
        if stroke.isHighlighter {
            color = color.withAlphaComponent(min(color.cgColor.alpha, 0.38))
        }
        let width = CGFloat(max(stroke.width, 0.25))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if stroke.points.count == 1 {
            let point = stroke.localPoints(in: size)[0]
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width))
            return
        }

        if !stroke.isHighlighter,
           stroke.pressures.count == stroke.points.count,
           let low = stroke.pressures.min(),
           let high = stroke.pressures.max(),
           high - low > 0.05 {
            drawPressureStroke(stroke, size: size, width: width, color: color, ctx: ctx)
            return
        }

        var effectiveWidth = width
        if !stroke.isHighlighter, let pressure = stroke.pressures.first {
            effectiveWidth = width * CanvasRenderer.pressureFactor(pressure)
        }
        ctx.addPath(cachedPath(for: stroke, id: id, size: size))
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(effectiveWidth)
        ctx.strokePath()
    }

    /// Pencil strokes: segments are grouped into runs of equal (quantized)
    /// width so a stroke costs a handful of draw calls rather than one per point.
    private func drawPressureStroke(_ stroke: StrokeContent, size: CGSize, width: CGFloat, color: UIColor, ctx: CGContext) {
        let points = stroke.localPoints(in: size)
        ctx.setStrokeColor(color.cgColor)
        var currentBucket = -1
        var path = CGMutablePath()

        func flush() {
            guard currentBucket >= 0, !path.isEmpty else { return }
            ctx.addPath(path)
            ctx.setLineWidth(width * CGFloat(currentBucket) / 10)
            ctx.strokePath()
        }

        for index in 1..<points.count {
            let pressure = (stroke.pressures[index - 1] + stroke.pressures[index]) / 2
            let bucket = max(1, Int((CanvasRenderer.pressureFactor(pressure) * 10).rounded()))
            if bucket != currentBucket {
                flush()
                path = CGMutablePath()
                path.move(to: points[index - 1])
                currentBucket = bucket
            }
            path.addLine(to: points[index])
        }
        flush()
    }

    private func cachedPath(for stroke: StrokeContent, id: UUID, size: CGSize) -> CGPath {
        if let cached = pathCache[id],
           cached.width == size.width,
           cached.height == size.height,
           cached.count == stroke.points.count {
            return cached.path
        }
        let path = CanvasRenderer.smoothPath(through: stroke.localPoints(in: size))
        if pathCache.count > 4_000 {
            pathCache.removeAll(keepingCapacity: true)
        }
        pathCache[id] = CachedPath(width: size.width, height: size.height, count: stroke.points.count, path: path)
        return path
    }

    /// Quadratic smoothing through segment midpoints.
    static func smoothPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count < 3 {
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            return path
        }
        for index in 1..<(points.count - 1) {
            let control = points[index]
            let next = points[index + 1]
            let mid = CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: control)
        }
        if let last = points.last {
            path.addLine(to: last)
        }
        return path
    }
}

// MARK: - Text metrics

enum TextMetrics {
    static func attributedString(for text: TextContent, color: UIColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = text.alignment.nsTextAlignment
        paragraph.lineBreakMode = .byWordWrapping
        let font = text.font.uiFont(size: CGFloat(text.fontSize), bold: text.isBold, italic: text.isItalic)
        return NSAttributedString(string: text.text.isEmpty ? " " : text.text,
                                  attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    static func height(for text: TextContent, width: CGFloat) -> CGFloat {
        let attributed = attributedString(for: text, color: .white)
        let bounds = attributed.boundingRect(with: CGSize(width: max(width, 10), height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                                             context: nil)
        return ceil(bounds.height) + 4
    }
}

extension BoardObject {
    /// Text objects keep their width; height always fits the content.
    mutating func fitTextHeight() {
        guard case .text(let text) = content else { return }
        frame.size.height = TextMetrics.height(for: text, width: frame.width)
    }
}
