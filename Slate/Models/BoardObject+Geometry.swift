import CoreGraphics
import Foundation

extension BoardObject {
    var center: CGPoint {
        frame.center
    }

    /// The object's frame expressed around its own center (unrotated).
    var localRect: CGRect {
        CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height)
    }

    func localToWorld(_ point: CGPoint) -> CGPoint {
        center + point.rotated(by: CGFloat(rotation))
    }

    func worldToLocal(_ point: CGPoint) -> CGPoint {
        (point - center).rotated(by: CGFloat(-rotation))
    }

    /// World-space corners in the order top-left, top-right, bottom-right, bottom-left.
    var worldCorners: [CGPoint] {
        let rect = localRect
        return [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ].map { localToWorld($0) }
    }

    /// Axis-aligned world bounds including rotation and stroke width. Used for
    /// visibility culling, export bounds and lasso selection.
    var boundingBox: CGRect {
        let base = rotation == 0 ? frame : CGRect.bounding(worldCorners)
        let padding = outlinePadding
        return base.insetBy(dx: -padding, dy: -padding)
    }

    private var outlinePadding: CGFloat {
        switch content {
        case .stroke(let stroke): return CGFloat(stroke.width) / 2 + 1
        case .sticky: return 4
        default: return 1
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch content {
        case .stroke(let stroke):
            let local = worldToLocal(point)
            let margin = tolerance + CGFloat(stroke.width)
            guard localRect.insetBy(dx: -margin, dy: -margin).contains(local) else { return false }
            let points = stroke.localPoints(in: frame.size)
            let limit = CGFloat(stroke.width) / 2 + tolerance
            guard let first = points.first else { return false }
            if points.count == 1 {
                return local.distance(to: first) <= limit
            }
            for index in 1..<points.count where local.distanceToSegment(from: points[index - 1], to: points[index]) <= limit {
                return true
            }
            return false
        default:
            return localRect.insetBy(dx: -tolerance, dy: -tolerance).contains(worldToLocal(point))
        }
    }
}
