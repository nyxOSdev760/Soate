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
        switch content {
        case .connector(let connector):
            let padding = CGFloat(connector.strokeWidth) * 3 + 12
            return connector.bounds.insetBy(dx: -padding, dy: -padding)
        default:
            let base = rotation == 0 ? frame : CGRect.bounding(worldCorners)
            let padding = outlinePadding
            return base.insetBy(dx: -padding, dy: -padding)
        }
    }

    private var outlinePadding: CGFloat {
        switch content {
        case .shape(let shape): return CGFloat(shape.strokeWidth) / 2 + 1
        case .stroke(let stroke): return CGFloat(stroke.width) / 2 + 1
        case .sticky: return 4
        default: return 1
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch content {
        case .connector(let connector):
            let limit = CGFloat(connector.strokeWidth) / 2 + tolerance
            return point.distanceToSegment(from: connector.start, to: connector.end) <= limit
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

enum ConnectorGeometry {
    /// The point on the outline of `object` where a connector heading toward
    /// `target` should attach.
    static func anchor(on object: BoardObject, toward target: CGPoint, gap: CGFloat = 6) -> CGPoint {
        let local = object.worldToLocal(target)
        let distance = local.length
        guard distance > 0.001 else { return object.center }
        let direction = local / distance
        let halfWidth = max(object.frame.width / 2, 0.5)
        let halfHeight = max(object.frame.height / 2, 0.5)
        var t: CGFloat
        if let shape = object.shapeContent, shape.kind == .ellipse {
            let dx = direction.x / halfWidth
            let dy = direction.y / halfHeight
            t = 1 / max(sqrt(dx * dx + dy * dy), 0.000_1)
        } else {
            let tx = abs(direction.x) > 0.000_1 ? halfWidth / abs(direction.x) : CGFloat.greatestFiniteMagnitude
            let ty = abs(direction.y) > 0.000_1 ? halfHeight / abs(direction.y) : CGFloat.greatestFiniteMagnitude
            t = min(tx, ty)
        }
        t = min(t + gap, distance)
        return object.localToWorld(direction * t)
    }

    /// The topmost object a connector endpoint at `point` should attach to.
    static func snapTarget(at point: CGPoint,
                           in objects: [BoardObject],
                           excluding excluded: Set<UUID>,
                           tolerance: CGFloat) -> BoardObject? {
        objects.last { object in
            guard !excluded.contains(object.id), !object.isConnector, !object.isStroke else { return false }
            return object.localRect.insetBy(dx: -tolerance, dy: -tolerance).contains(object.worldToLocal(point))
        }
    }
}
