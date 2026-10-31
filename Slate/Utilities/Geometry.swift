import CoreGraphics
import Foundation

extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
        CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
    }

    static func / (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
        CGPoint(x: lhs.x / rhs, y: lhs.y / rhs)
    }

    var length: CGFloat {
        hypot(x, y)
    }

    var isFiniteValue: Bool {
        x.isFinite && y.isFinite
    }

    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }

    func rotated(by angle: CGFloat) -> CGPoint {
        if angle == 0 { return self }
        let c = cos(angle)
        let s = sin(angle)
        return CGPoint(x: x * c - y * s, y: x * s + y * c)
    }

    func distanceToSegment(from a: CGPoint, to b: CGPoint) -> CGFloat {
        let abX = b.x - a.x
        let abY = b.y - a.y
        let lengthSquared = abX * abX + abY * abY
        guard lengthSquared > 0.000_1 else { return distance(to: a) }
        var t = ((x - a.x) * abX + (y - a.y) * abY) / lengthSquared
        t = max(0, min(1, t))
        return distance(to: CGPoint(x: a.x + abX * t, y: a.y + abY * t))
    }
}

extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    init(center: CGPoint, size: CGSize) {
        self.init(x: center.x - size.width / 2,
                  y: center.y - size.height / 2,
                  width: size.width,
                  height: size.height)
    }

    init(corner a: CGPoint, corner b: CGPoint) {
        self.init(x: min(a.x, b.x),
                  y: min(a.y, b.y),
                  width: abs(a.x - b.x),
                  height: abs(a.y - b.y))
    }

    static func bounding(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

enum GeometryUtils {
    /// Even-odd ray casting test.
    static func polygon(_ polygon: [CGPoint], contains point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            if (pi.y > point.y) != (pj.y > point.y) {
                let crossing = (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x
                if point.x < crossing {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    static func normalizedAngle(_ angle: Double) -> Double {
        var result = angle.truncatingRemainder(dividingBy: 2 * Double.pi)
        if result > Double.pi { result -= 2 * Double.pi }
        if result < -Double.pi { result += 2 * Double.pi }
        return result
    }
}
