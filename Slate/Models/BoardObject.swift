import CoreGraphics
import Foundation
import UIKit

enum ShapeKind: String, Codable, CaseIterable, Identifiable {
    case rectangle
    case roundedRectangle
    case ellipse
    case triangle
    case line
    case arrow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .roundedRectangle: return "Rounded Rectangle"
        case .ellipse: return "Ellipse"
        case .triangle: return "Triangle"
        case .line: return "Line"
        case .arrow: return "Arrow"
        }
    }

    var systemImage: String {
        switch self {
        case .rectangle: return "rectangle"
        case .roundedRectangle: return "app"
        case .ellipse: return "circle"
        case .triangle: return "triangle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        }
    }

    /// Lines and arrows are stored as connectors that can attach to objects.
    var isConnector: Bool {
        self == .line || self == .arrow
    }
}

enum PenKind: String, Codable, CaseIterable, Identifiable {
    case pen
    case highlighter
    case eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .eraser: return "Eraser"
        }
    }

    var systemImage: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        }
    }
}

enum TextAlign: String, Codable, CaseIterable, Identifiable {
    case left
    case center
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }

    var systemImage: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}

struct TextContent: Codable, Equatable {
    var text: String
    var font: FontFamily
    var fontSize: Double
    var isBold: Bool
    var isItalic: Bool
    var alignment: TextAlign
    var color: PaintColor
}

struct ImageContent: Codable, Equatable {
    var imageID: String
    var opacity: Double
}

struct ShapeContent: Codable, Equatable {
    var kind: ShapeKind
    var fill: PaintColor
    var stroke: PaintColor
    var strokeWidth: Double
}

/// A line or arrow. Endpoints are in world coordinates. When an endpoint is
/// bound to an object it is recomputed to follow that object.
struct ConnectorContent: Codable, Equatable {
    var start: CGPoint
    var end: CGPoint
    var startBinding: UUID?
    var endBinding: UUID?
    var hasArrowhead: Bool
    var stroke: PaintColor
    var strokeWidth: Double

    var bounds: CGRect {
        CGRect.bounding([start, end])
    }
}

struct StickyContent: Codable, Equatable {
    var text: String
    var color: PaintColor
    var fontSize: Double
}

/// A freehand stroke. Points are normalized (0...1) inside the object's frame
/// so strokes can be moved, resized and rotated like any other object.
struct StrokeContent: Codable, Equatable {
    var points: [CGPoint]
    var pressures: [Double]
    var color: PaintColor
    var width: Double
    var isHighlighter: Bool

    func localPoints(in size: CGSize) -> [CGPoint] {
        points.map { point in
            CGPoint(x: -size.width / 2 + point.x * size.width,
                    y: -size.height / 2 + point.y * size.height)
        }
    }
}

enum ObjectContent: Codable, Equatable {
    case text(TextContent)
    case image(ImageContent)
    case shape(ShapeContent)
    case connector(ConnectorContent)
    case sticky(StickyContent)
    case stroke(StrokeContent)
}

/// Every item on a board. `frame` is the unrotated world-space frame;
/// `rotation` (radians) is applied around the frame's center.
struct BoardObject: Codable, Identifiable, Equatable {
    var id: UUID
    var frame: CGRect
    var rotation: Double
    var isLocked: Bool
    var content: ObjectContent

    init(id: UUID = UUID(),
         frame: CGRect,
         rotation: Double = 0,
         isLocked: Bool = false,
         content: ObjectContent) {
        self.id = id
        self.frame = frame
        self.rotation = rotation
        self.isLocked = isLocked
        self.content = content
    }
}

// MARK: - Accessors

extension BoardObject {
    var kindName: String {
        switch content {
        case .text: return "Text"
        case .image: return "Image"
        case .shape(let shape): return shape.kind.title
        case .connector(let connector): return connector.hasArrowhead ? "Arrow" : "Line"
        case .sticky: return "Sticky Note"
        case .stroke(let stroke): return stroke.isHighlighter ? "Highlight" : "Drawing"
        }
    }

    var isConnector: Bool {
        if case .connector = content { return true }
        return false
    }

    var isStroke: Bool {
        if case .stroke = content { return true }
        return false
    }

    var isEditableText: Bool {
        switch content {
        case .text, .sticky: return true
        default: return false
        }
    }

    var supportsRotation: Bool {
        !isConnector
    }

    var keepsAspectRatio: Bool {
        switch content {
        case .image, .sticky: return true
        default: return false
        }
    }

    var textContent: TextContent? {
        if case .text(let value) = content { return value }
        return nil
    }

    var imageContent: ImageContent? {
        if case .image(let value) = content { return value }
        return nil
    }

    var shapeContent: ShapeContent? {
        if case .shape(let value) = content { return value }
        return nil
    }

    var connectorContent: ConnectorContent? {
        if case .connector(let value) = content { return value }
        return nil
    }

    var stickyContent: StickyContent? {
        if case .sticky(let value) = content { return value }
        return nil
    }

    var strokeContent: StrokeContent? {
        if case .stroke(let value) = content { return value }
        return nil
    }

    var textValue: String? {
        switch content {
        case .text(let value): return value.text
        case .sticky(let value): return value.text
        default: return nil
        }
    }

    mutating func setTextValue(_ newValue: String) {
        switch content {
        case .text(var value):
            value.text = newValue
            content = .text(value)
            fitTextHeight()
        case .sticky(var value):
            value.text = newValue
            content = .sticky(value)
        default:
            break
        }
    }

    mutating func modifyText(_ change: (inout TextContent) -> Void) {
        guard case .text(var value) = content else { return }
        change(&value)
        content = .text(value)
        fitTextHeight()
    }

    mutating func modifyShape(_ change: (inout ShapeContent) -> Void) {
        guard case .shape(var value) = content else { return }
        change(&value)
        content = .shape(value)
    }

    mutating func modifyConnector(_ change: (inout ConnectorContent) -> Void) {
        guard case .connector(var value) = content else { return }
        change(&value)
        content = .connector(value)
        frame = value.bounds
    }

    mutating func modifySticky(_ change: (inout StickyContent) -> Void) {
        guard case .sticky(var value) = content else { return }
        change(&value)
        content = .sticky(value)
    }

    mutating func modifyImage(_ change: (inout ImageContent) -> Void) {
        guard case .image(var value) = content else { return }
        change(&value)
        content = .image(value)
    }

    mutating func modifyStroke(_ change: (inout StrokeContent) -> Void) {
        guard case .stroke(var value) = content else { return }
        change(&value)
        content = .stroke(value)
    }
}

// MARK: - Factories

extension BoardObject {
    static func makeStroke(worldPoints: [CGPoint],
                           pressures: [Double],
                           color: PaintColor,
                           width: Double,
                           isHighlighter: Bool,
                           id: UUID = UUID()) -> BoardObject {
        let padding = CGFloat(width) / 2 + 1
        var bounds = CGRect.bounding(worldPoints)
        if bounds.isNull {
            bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        bounds = bounds.insetBy(dx: -padding, dy: -padding)
        let frameWidth = max(bounds.width, 1)
        let frameHeight = max(bounds.height, 1)
        let normalized = worldPoints.map { point in
            CGPoint(x: (point.x - bounds.minX) / frameWidth, y: (point.y - bounds.minY) / frameHeight)
        }
        let validPressures = pressures.count == worldPoints.count ? pressures : []
        let content = StrokeContent(points: normalized,
                                    pressures: validPressures,
                                    color: color,
                                    width: width,
                                    isHighlighter: isHighlighter)
        return BoardObject(id: id,
                           frame: CGRect(x: bounds.minX, y: bounds.minY, width: frameWidth, height: frameHeight),
                           content: .stroke(content))
    }

    static func makeShape(kind: ShapeKind, frame: CGRect, strokeWidth: Double) -> BoardObject {
        let content = ShapeContent(kind: kind,
                                   fill: .clear,
                                   stroke: .themeForeground,
                                   strokeWidth: strokeWidth)
        return BoardObject(frame: frame, content: .shape(content))
    }

    static func makeConnector(start: CGPoint,
                              end: CGPoint,
                              hasArrowhead: Bool,
                              strokeWidth: Double,
                              startBinding: UUID? = nil,
                              endBinding: UUID? = nil) -> BoardObject {
        let content = ConnectorContent(start: start,
                                       end: end,
                                       startBinding: startBinding,
                                       endBinding: endBinding,
                                       hasArrowhead: hasArrowhead,
                                       stroke: .themeForeground,
                                       strokeWidth: strokeWidth)
        return BoardObject(frame: content.bounds, content: .connector(content))
    }
}
