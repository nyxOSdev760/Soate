import CoreGraphics
import Foundation

/// Maps world (board) coordinates to screen coordinates:
/// `screen = world * scale + offset`.
struct Viewport: Codable, Equatable {
    static let minScale: Double = 0.1
    static let maxScale: Double = 8

    var offsetX: Double = 0
    var offsetY: Double = 0
    var scale: Double = 1

    init(offsetX: Double = 0, offsetY: Double = 0, scale: Double = 1) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.scale = scale
    }

    var isValid: Bool {
        offsetX.isFinite && offsetY.isFinite && scale.isFinite && scale > 0
    }

    func toScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * CGFloat(scale) + CGFloat(offsetX),
                y: point.y * CGFloat(scale) + CGFloat(offsetY))
    }

    func toWorld(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - CGFloat(offsetX)) / CGFloat(scale),
                y: (point.y - CGFloat(offsetY)) / CGFloat(scale))
    }

    func worldRect(forScreen rect: CGRect) -> CGRect {
        let origin = toWorld(rect.origin)
        return CGRect(x: origin.x,
                      y: origin.y,
                      width: rect.width / CGFloat(scale),
                      height: rect.height / CGFloat(scale))
    }

    mutating func pan(by translation: CGPoint) {
        offsetX += Double(translation.x)
        offsetY += Double(translation.y)
    }

    mutating func zoom(by factor: Double, around screenPoint: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let anchor = toWorld(screenPoint)
        scale = min(max(scale * factor, Viewport.minScale), Viewport.maxScale)
        offsetX = Double(screenPoint.x) - Double(anchor.x) * scale
        offsetY = Double(screenPoint.y) - Double(anchor.y) * scale
    }
}
