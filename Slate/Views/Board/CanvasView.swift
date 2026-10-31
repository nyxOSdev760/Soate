import SwiftUI
import UIKit

/// Bridges the UIKit canvas into SwiftUI.
struct CanvasRepresentable: UIViewRepresentable {
    let viewModel: BoardViewModel

    func makeUIView(context: Context) -> CanvasUIView {
        let view = CanvasUIView(frame: .zero)
        view.attach(viewModel)
        return view
    }

    func updateUIView(_ uiView: CanvasUIView, context: Context) {
        if uiView.viewModel !== viewModel {
            uiView.attach(viewModel)
        }
        uiView.refresh()
    }
}

/// Transparent layer above the canvas for selection handles, the lasso, the
/// in-progress stroke and the eraser cursor. Redrawing it is cheap, so
/// interactive feedback does not require redrawing the whole board.
final class CanvasOverlayView: UIView {
    weak var canvas: CanvasUIView?

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        canvas?.drawOverlay(in: ctx)
    }
}

/// The infinite canvas. Draws the board with Core Graphics (only objects in
/// the visible rect), handles single-touch tools directly for low latency and
/// Apple Pencil pressure, and uses gesture recognizers for two-finger pan,
/// pinch-zoom, double-tap editing and two-finger-tap multi-select.
final class CanvasUIView: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    private(set) weak var viewModel: BoardViewModel?

    private let renderer = CanvasRenderer()
    private let overlay = CanvasOverlayView()
    private let liveStrokeID = UUID()

    private var pinchRecognizer: UIPinchGestureRecognizer!
    private var panRecognizer: UIPanGestureRecognizer!
    private var doubleTapRecognizer: UITapGestureRecognizer!
    private var twoFingerTapRecognizer: UITapGestureRecognizer!

    private enum Mode: Equatable {
        case idle
        case drawing
        case erasing
        case lasso
        case moving
        case resizing(corner: Int)
        case rotating
        case pendingTap
    }

    private enum Handle {
        case corner(Int)
        case rotate
    }

    private struct HandleHit {
        let object: BoardObject
        let handle: Handle
    }

    private var mode: Mode = .idle
    private weak var activeTouch: UITouch?
    private var isPencilStroke = false
    private var startScreen: CGPoint = .zero
    private var startWorld: CGPoint = .zero
    private var lastWorld: CGPoint = .zero
    private var didMove = false
    private var livePoints: [CGPoint] = []
    private var livePressures: [Double] = []
    private var lassoPoints: [CGPoint] = []
    private var originals: [UUID: BoardObject] = [:]
    private var originalObject: BoardObject?
    private var tappedObjectID: UUID?
    private var eraserScreenPoint: CGPoint?
    private var lastLayoutSize: CGSize = .zero

    private static let handleRadius: CGFloat = 24
    private static let rotateHandleDistance: CGFloat = 30

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        isOpaque = true
        backgroundColor = .black
        contentMode = .redraw
        isMultipleTouchEnabled = true
        clearsContextBeforeDrawing = false

        overlay.canvas = self
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        overlay.contentMode = .redraw
        overlay.frame = bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(overlay)

        pinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchRecognizer.delegate = self
        addGestureRecognizer(pinchRecognizer)

        panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panRecognizer.minimumNumberOfTouches = 2
        panRecognizer.maximumNumberOfTouches = 2
        panRecognizer.allowedScrollTypesMask = .continuous
        panRecognizer.delegate = self
        addGestureRecognizer(panRecognizer)

        doubleTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapRecognizer.numberOfTapsRequired = 2
        doubleTapRecognizer.cancelsTouchesInView = false
        doubleTapRecognizer.delaysTouchesEnded = false
        doubleTapRecognizer.delegate = self
        addGestureRecognizer(doubleTapRecognizer)

        twoFingerTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTapRecognizer.numberOfTouchesRequired = 2
        twoFingerTapRecognizer.delaysTouchesEnded = false
        twoFingerTapRecognizer.delegate = self
        addGestureRecognizer(twoFingerTapRecognizer)

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        addInteraction(pencilInteraction)

        isAccessibilityElement = true
        accessibilityLabel = "Whiteboard canvas"
        accessibilityHint = "Use two fingers to pan and pinch to zoom."
    }

    func attach(_ viewModel: BoardViewModel) {
        self.viewModel = viewModel
        viewModel.onRedraw = { [weak self] in
            self?.refresh()
        }
        viewModel.viewSize = bounds.size
        refresh()
    }

    func refresh() {
        setNeedsDisplay()
        overlay.setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlay.frame = bounds
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            viewModel?.viewSize = bounds.size
            refresh()
        }
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        guard let viewModel else {
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(rect)
            return
        }
        let viewport = viewModel.viewport
        let theme = viewModel.renderTheme
        let scale = CGFloat(viewport.scale)
        let worldRect = viewport.worldRect(forScreen: rect)

        ctx.saveGState()
        ctx.translateBy(x: CGFloat(viewport.offsetX), y: CGFloat(viewport.offsetY))
        ctx.scaleBy(x: scale, y: scale)
        renderer.drawBackground(in: ctx, worldRect: worldRect, theme: theme, pattern: viewModel.board.pattern, scale: scale)
        renderer.drawObjects(viewModel.board.objects, in: ctx, theme: theme, visibleRect: worldRect)
        ctx.restoreGState()
    }

    func drawOverlay(in ctx: CGContext) {
        guard let viewModel else { return }
        let viewport = viewModel.viewport
        let theme = viewModel.renderTheme
        let accent = theme.accent.uiColor
        let scale = CGFloat(viewport.scale)

        // In-progress freehand stroke.
        if mode == .drawing, !livePoints.isEmpty {
            let stroke = viewModel.makeStrokeObject(points: livePoints, pressures: livePressures, id: liveStrokeID)
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(viewport.offsetX), y: CGFloat(viewport.offsetY))
            ctx.scaleBy(x: scale, y: scale)
            renderer.draw(stroke, in: ctx, theme: theme)
            ctx.restoreGState()
        }

        // Selection outlines and handles.
        let selected = viewModel.board.objects.filter { viewModel.selection.contains($0.id) }
        for object in selected {
            drawSelectionOutline(for: object, viewport: viewport, accent: accent, ctx: ctx)
        }
        if selected.count == 1, let object = selected.first, !object.isLocked, mode != .drawing {
            drawHandles(for: object, viewport: viewport, accent: accent, ctx: ctx)
        }

        // Lasso.
        if mode == .lasso, lassoPoints.count > 1 {
            let points = lassoPoints.map { viewport.toScreen($0) }
            ctx.saveGState()
            ctx.addLines(between: points)
            ctx.closePath()
            ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            ctx.fillPath()
            ctx.addLines(between: points)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Eraser cursor.
        if let eraserScreenPoint {
            let radius = CGFloat(viewModel.eraserWidth) / 2
            ctx.saveGState()
            ctx.setStrokeColor(theme.foreground.withAlpha(0.7).cgColor)
            ctx.setFillColor(theme.foreground.withAlpha(0.08).cgColor)
            ctx.setLineWidth(1.5)
            let circle = CGRect(x: eraserScreenPoint.x - radius, y: eraserScreenPoint.y - radius, width: radius * 2, height: radius * 2)
            ctx.fillEllipse(in: circle)
            ctx.strokeEllipse(in: circle)
            ctx.restoreGState()
        }
    }

    private func drawSelectionOutline(for object: BoardObject, viewport: Viewport, accent: UIColor, ctx: CGContext) {
        ctx.saveGState()
        let points = object.worldCorners.map { viewport.toScreen($0) }
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5)
        if object.isLocked {
            ctx.setLineDash(phase: 0, lengths: [5, 4])
        }
        ctx.addLines(between: points)
        ctx.closePath()
        ctx.strokePath()
        ctx.restoreGState()

        if object.isLocked {
            let anchor = viewport.toScreen(object.worldCorners[0])
            let badge = CGRect(x: anchor.x - 4, y: anchor.y - 26, width: 22, height: 22)
            ctx.saveGState()
            ctx.setFillColor(accent.cgColor)
            ctx.fillEllipse(in: badge)
            ctx.restoreGState()
            if let image = UIImage(systemName: "lock.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                image.draw(in: badge.insetBy(dx: 5, dy: 4.5))
            }
        }
    }

    private func drawHandles(for object: BoardObject, viewport: Viewport, accent: UIColor, ctx: CGContext) {
        let corners = object.worldCorners.map { viewport.toScreen($0) }
        do {
            let top = rotationHandleBase(for: object, viewport: viewport)
            let handle = rotationHandlePoint(for: object, viewport: viewport)
            ctx.saveGState()
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: top)
            ctx.addLine(to: handle)
            ctx.strokePath()
            ctx.setFillColor(accent.cgColor)
            ctx.fillEllipse(in: CGRect(x: handle.x - 7, y: handle.y - 7, width: 14, height: 14))
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: handle.x - 7, y: handle.y - 7, width: 14, height: 14))
            ctx.restoreGState()
        }
        for corner in corners {
            drawHandleDot(at: corner, accent: accent, ctx: ctx)
        }
    }

    private func drawHandleDot(at point: CGPoint, accent: UIColor, ctx: CGContext) {
        let rect = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
        ctx.saveGState()
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: rect)
        ctx.restoreGState()
    }

    private func rotationHandleBase(for object: BoardObject, viewport: Viewport) -> CGPoint {
        viewport.toScreen(object.localToWorld(CGPoint(x: 0, y: -object.frame.height / 2)))
    }

    private func rotationHandlePoint(for object: BoardObject, viewport: Viewport) -> CGPoint {
        let up = CGPoint(x: 0, y: -1).rotated(by: CGFloat(object.rotation))
        return rotationHandleBase(for: object, viewport: viewport) + up * CanvasUIView.rotateHandleDistance
    }

    private func handleHit(at screen: CGPoint) -> HandleHit? {
        guard let viewModel,
              viewModel.selection.count == 1,
              let id = viewModel.selection.first,
              let object = viewModel.object(withID: id),
              !object.isLocked else { return nil }
        let viewport = viewModel.viewport
        let radius = CanvasUIView.handleRadius
        if rotationHandlePoint(for: object, viewport: viewport).distance(to: screen) <= radius {
            return HandleHit(object: object, handle: .rotate)
        }
        let corners = object.worldCorners.map { viewport.toScreen($0) }
        var best: (index: Int, distance: CGFloat)?
        for (index, corner) in corners.enumerated() {
            let distance = corner.distance(to: screen)
            if distance <= radius, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (index, distance)
            }
        }
        if let best {
            return HandleHit(object: object, handle: .corner(best.index))
        }
        return nil
    }

    // MARK: Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let viewModel, let touch = touches.first else { return }
        if let active = activeTouch {
            // A pencil stroke wins over resting fingers; otherwise a second
            // finger means a pan/zoom is starting.
            if active.type != .pencil {
                cancelActiveInteraction()
            }
            return
        }
        let liveTouches = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? touches
        if liveTouches.count > 1 && touch.type != .pencil {
            return
        }

        activeTouch = touch
        isPencilStroke = touch.type == .pencil
        let screen = touch.location(in: self)
        let world = viewModel.viewport.toWorld(screen)
        startScreen = screen
        startWorld = world
        lastWorld = world
        didMove = false

        switch viewModel.tool {
        case .pen:
            if viewModel.penKind == .eraser {
                mode = .erasing
                viewModel.beginInteraction()
                eraserScreenPoint = screen
                viewModel.erase(from: world, to: world, radius: eraserRadius)
            } else {
                mode = .drawing
                livePoints = [world]
                livePressures = isPencilStroke ? [pressure(of: touch)] : []
            }
        case .select:
            beginSelectInteraction(screen: screen, world: world)
        case .text, .sticky:
            mode = .pendingTap
        }
        overlay.setNeedsDisplay()
    }

    private func beginSelectInteraction(screen: CGPoint, world: CGPoint) {
        guard let viewModel else { return }
        if let hit = handleHit(at: screen) {
            originalObject = hit.object
            viewModel.beginInteraction()
            switch hit.handle {
            case .corner(let index): mode = .resizing(corner: index)
            case .rotate: mode = .rotating
            }
            return
        }
        let tolerance = 10 / CGFloat(viewModel.viewport.scale)
        if let hit = viewModel.topObject(at: world, tolerance: tolerance) {
            tappedObjectID = hit.id
            if !viewModel.selection.contains(hit.id) {
                viewModel.select([hit.id])
            }
            originals = viewModel.movableSelection()
            mode = .moving
            viewModel.beginInteraction()
        } else {
            mode = .lasso
            lassoPoints = [world]
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let viewModel, let touch = activeTouch, touches.contains(touch) else { return }
        let screen = touch.location(in: self)
        let world = viewModel.viewport.toWorld(screen)
        if !didMove && screen.distance(to: startScreen) > 4 {
            didMove = true
        }

        switch mode {
        case .drawing:
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            let scale = CGFloat(viewModel.viewport.scale)
            for sample in samples {
                let point = viewModel.viewport.toWorld(sample.location(in: self))
                if let last = livePoints.last, last.distance(to: point) * scale < 0.75 {
                    continue
                }
                livePoints.append(point)
                if isPencilStroke {
                    livePressures.append(pressure(of: sample))
                }
            }
            overlay.setNeedsDisplay()
        case .erasing:
            viewModel.erase(from: lastWorld, to: world, radius: eraserRadius)
            eraserScreenPoint = screen
            overlay.setNeedsDisplay()
        case .lasso:
            lassoPoints.append(world)
            overlay.setNeedsDisplay()
        case .moving:
            if didMove {
                viewModel.moveObjects(originals, by: world - startWorld)
            }
        case .resizing(let corner):
            if let originalObject {
                viewModel.resize(originalObject, corner: corner, to: world)
            }
        case .rotating:
            if let originalObject {
                viewModel.rotate(originalObject, toward: world)
            }
        case .pendingTap, .idle:
            break
        }
        lastWorld = world
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let viewModel, let touch = activeTouch, touches.contains(touch) else { return }
        let world = viewModel.viewport.toWorld(touch.location(in: self))
        let tolerance = 10 / CGFloat(viewModel.viewport.scale)

        switch mode {
        case .drawing:
            viewModel.addStroke(points: livePoints, pressures: livePressures)
        case .erasing:
            viewModel.endInteraction()
        case .lasso:
            if didMove && lassoPoints.count > 2 {
                viewModel.selectObjects(inLasso: lassoPoints)
            } else {
                viewModel.clearSelection()
            }
        case .moving:
            viewModel.endInteraction()
            if !didMove, let tappedObjectID, viewModel.selection.count > 1 {
                viewModel.select([tappedObjectID])
            }
        case .resizing, .rotating:
            viewModel.endInteraction()
        case .pendingTap:
            if !didMove {
                viewModel.handleTap(at: world, tolerance: tolerance)
            }
        case .idle:
            break
        }
        resetInteractionState()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        cancelActiveInteraction()
    }

    private func cancelActiveInteraction() {
        switch mode {
        case .erasing, .moving, .resizing, .rotating:
            viewModel?.cancelInteraction()
        case .idle, .drawing, .lasso, .pendingTap:
            break
        }
        resetInteractionState()
    }

    private func resetInteractionState() {
        mode = .idle
        activeTouch = nil
        isPencilStroke = false
        didMove = false
        livePoints = []
        livePressures = []
        lassoPoints = []
        originals = [:]
        originalObject = nil
        tappedObjectID = nil
        eraserScreenPoint = nil
        overlay.setNeedsDisplay()
    }

    private var eraserRadius: CGFloat {
        guard let viewModel else { return 10 }
        return CGFloat(viewModel.eraserWidth) / 2 / CGFloat(viewModel.viewport.scale)
    }

    private func pressure(of touch: UITouch) -> Double {
        guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return 0.6 }
        return Double(min(max(touch.force / touch.maximumPossibleForce, 0), 1))
    }

    // MARK: Gestures

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let viewModel else { return false }
        if gestureRecognizer === doubleTapRecognizer {
            return viewModel.tool == .select || viewModel.tool == .text || viewModel.tool == .sticky
        }
        if gestureRecognizer === twoFingerTapRecognizer {
            return viewModel.tool == .select
        }
        if gestureRecognizer === panRecognizer || gestureRecognizer === pinchRecognizer {
            // Keep drawing with the pencil when a palm or finger rests on screen.
            if let activeTouch, activeTouch.type == .pencil {
                return false
            }
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let viewportRecognizers: [UIGestureRecognizer] = [pinchRecognizer, panRecognizer]
        return viewportRecognizers.contains { $0 === gestureRecognizer }
            && viewportRecognizers.contains { $0 === otherGestureRecognizer }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let viewModel else { return }
        switch recognizer.state {
        case .began, .changed:
            viewModel.viewport.zoom(by: Double(recognizer.scale), around: recognizer.location(in: self))
            recognizer.scale = 1
            refresh()
        case .ended, .cancelled, .failed:
            viewModel.viewportDidChange()
        default:
            break
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let viewModel else { return }
        switch recognizer.state {
        case .began, .changed:
            viewModel.viewport.pan(by: recognizer.translation(in: self))
            recognizer.setTranslation(.zero, in: self)
            refresh()
        case .ended, .cancelled, .failed:
            viewModel.viewportDidChange()
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let viewModel else { return }
        let world = viewModel.viewport.toWorld(recognizer.location(in: self))
        let tolerance = 10 / CGFloat(viewModel.viewport.scale)
        if let hit = viewModel.topObject(at: world, tolerance: tolerance), hit.isEditableText, !hit.isLocked {
            viewModel.beginEditing(hit.id)
        }
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        guard let viewModel else { return }
        let world = viewModel.viewport.toWorld(recognizer.location(in: self))
        let tolerance = 14 / CGFloat(viewModel.viewport.scale)
        if let hit = viewModel.topObject(at: world, tolerance: tolerance) {
            viewModel.toggleSelection(hit.id)
        }
    }

    // MARK: Apple Pencil

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        viewModel?.togglePencilEraser()
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        viewModel?.togglePencilEraser()
    }
}
