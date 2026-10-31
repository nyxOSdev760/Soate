import SwiftUI
import UIKit
import Observation

enum Tool: String, CaseIterable, Identifiable {
    case select
    case text
    case pen
    case sticky

    var id: String { rawValue }

    /// Tools with an options panel (color, thickness, palette).
    var hasOptions: Bool {
        self == .pen || self == .sticky
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Owns one open board: its objects, selection, tools, undo history,
/// viewport and autosave.
///
/// The board itself is not observed directly. Discrete changes bump
/// `revision`, which SwiftUI observes; continuous changes during a drag only
/// redraw the canvas so the SwiftUI hierarchy is not re-evaluated every frame.
@MainActor
@Observable
final class BoardViewModel {
    // MARK: Observed UI state

    private(set) var revision: Int = 0
    var selection: Set<UUID> = []
    var tool: Tool = .select
    /// Whether the active tool's options panel is showing. It opens when a
    /// tool is picked, toggles when the active tool is tapped again, and
    /// fades away when the board is touched.
    var showToolOptions = false
    var penKind: PenKind = .pen
    var penColor: PaintColor = .themeForeground
    var penWidth: Double = 4
    var highlighterColor: PaintColor = .custom(Palette.yellow)
    var highlighterWidth: Double = 20
    var eraserWidth: Double = 30
    var stickyColorIndex: Int = 0
    var editingTextID: UUID?
    var noticeMessage: String?
    var storageWarning: String?
    var shareItem: ShareItem?

    // MARK: Unobserved state

    @ObservationIgnored private(set) var board: Board
    @ObservationIgnored var viewport: Viewport
    @ObservationIgnored var viewSize: CGSize = .zero
    @ObservationIgnored var onRedraw: (() -> Void)?
    @ObservationIgnored private var interactionSnapshot: BoardSnapshot?
    @ObservationIgnored private var interactionRecorded = false
    @ObservationIgnored private var lastRotationSnapped = false
    @ObservationIgnored private var lastDrawingPenKind: PenKind = .pen
    @ObservationIgnored private var lastTextFont: FontFamily = .sanFrancisco
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false

    private let history = BoardUndoManager()
    private let autosave: AutosaveService
    private let store: BoardStore
    private let imageStore: ImageStore
    private let exportService: ExportService

    init(board: Board, store: BoardStore = .shared, imageStore: ImageStore = .shared) {
        self.board = board
        self.viewport = board.viewport.isValid ? board.viewport : Viewport()
        self.store = store
        self.imageStore = imageStore
        self.exportService = ExportService(imageStore: imageStore)
        self.autosave = AutosaveService(store: store)
        autosave.snapshotProvider = { [weak self] in
            self?.boardForSaving()
        }
        autosave.thumbnailProvider = { [weak self] board in
            self?.exportService.thumbnailData(for: board)
        }
        autosave.onResult = { [weak self] result in
            self?.handleSaveResult(result)
        }
        if store.isStorageLow {
            storageWarning = "Storage is almost full. Free up space to keep saving."
        }
    }

    // MARK: Read accessors (observed through `revision`)

    var theme: Theme {
        _ = revision
        return ThemeManager.shared.theme(for: board.themeID)
    }

    /// Theme lookup for rendering, without observation tracking.
    var renderTheme: Theme {
        ThemeManager.shared.theme(for: board.themeID)
    }

    var boardName: String {
        _ = revision
        return board.name
    }

    var pattern: BackgroundPattern {
        _ = revision
        return board.pattern
    }

    var themeID: ThemeID {
        _ = revision
        return board.themeID
    }

    var selectedObjects: [BoardObject] {
        _ = revision
        return board.objects.filter { selection.contains($0.id) }
    }

    var canUndo: Bool {
        _ = revision
        return history.canUndo
    }

    var canRedo: Bool {
        _ = revision
        return history.canRedo
    }

    var editingText: String {
        _ = revision
        guard let id = editingTextID, let object = object(withID: id) else { return "" }
        return object.textValue ?? ""
    }

    var editingIsSticky: Bool {
        _ = revision
        guard let id = editingTextID else { return false }
        return object(withID: id)?.stickyContent != nil
    }

    func object(withID id: UUID) -> BoardObject? {
        board.objects.first { $0.id == id }
    }

    private func index(of id: UUID) -> Int? {
        board.objects.firstIndex { $0.id == id }
    }

    func visibleWorldRect() -> CGRect {
        let size = viewSize == .zero ? CGSize(width: 390, height: 844) : viewSize
        return viewport.worldRect(forScreen: CGRect(origin: .zero, size: size))
    }

    private var zoom: CGFloat {
        CGFloat(viewport.scale)
    }

    // MARK: Change plumbing

    private func snapshot() -> BoardSnapshot {
        BoardSnapshot(objects: board.objects, themeID: board.themeID, pattern: board.pattern)
    }

    private func apply(_ snapshot: BoardSnapshot) {
        board.objects = snapshot.objects
        board.themeID = snapshot.themeID
        board.pattern = snapshot.pattern
        let ids = Set(snapshot.objects.map(\.id))
        selection = selection.intersection(ids)
        if let editing = editingTextID, !ids.contains(editing) {
            editingTextID = nil
        }
    }

    /// Discrete, undoable change.
    private func perform(_ coalescingKey: String? = nil, _ change: (inout Board) -> Void) {
        let before = snapshot()
        let pushed = history.record(before, coalescingKey: coalescingKey)
        change(&board)
        if pushed && snapshot() == before {
            history.discardLast()
            return
        }
        commitChange()
    }

    private func commitChange() {
        board.updatedAt = Date()
        revision &+= 1
        onRedraw?()
        autosave.scheduleSave()
    }

    private func liveChange() {
        board.updatedAt = Date()
        onRedraw?()
        autosave.scheduleSave()
    }

    // MARK: Continuous interactions (drag, resize, rotate, erase)

    func beginInteraction() {
        interactionSnapshot = snapshot()
        interactionRecorded = false
        lastRotationSnapped = false
    }

    private func recordInteractionIfNeeded() {
        guard !interactionRecorded else { return }
        history.record(interactionSnapshot ?? snapshot())
        interactionRecorded = true
    }

    func endInteraction() {
        let changed = interactionRecorded
        interactionSnapshot = nil
        interactionRecorded = false
        if changed {
            commitChange()
        } else {
            onRedraw?()
        }
    }

    func cancelInteraction() {
        if interactionRecorded, let snapshot = interactionSnapshot {
            apply(snapshot)
            history.discardLast()
            commitChange()
        }
        interactionSnapshot = nil
        interactionRecorded = false
        onRedraw?()
    }

    private func liveReplace(_ objects: [BoardObject]) {
        recordInteractionIfNeeded()
        for object in objects {
            if let index = index(of: object.id) {
                board.objects[index] = object
            }
        }
        liveChange()
    }

    // MARK: Hit testing and selection

    func topObject(at point: CGPoint, tolerance: CGFloat) -> BoardObject? {
        board.objects.last { $0.hitTest(point, tolerance: tolerance) }
    }

    func select(_ ids: Set<UUID>) {
        if let editing = editingTextID, !ids.contains(editing) {
            endEditing()
        }
        selection = ids
        onRedraw?()
    }

    func toggleSelection(_ id: UUID) {
        if tool != .select {
            tool = .select
        }
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        Haptics.selection()
        onRedraw?()
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        if editingTextID != nil {
            endEditing()
        }
        selection = []
        onRedraw?()
    }

    func selectAll() {
        tool = .select
        selection = Set(board.objects.map(\.id))
        onRedraw?()
    }

    func selectObjects(inLasso polygon: [CGPoint]) {
        let ids = board.objects
            .filter { GeometryUtils.polygon(polygon, contains: $0.boundingBox.center) }
            .map(\.id)
        selection = Set(ids)
        if !ids.isEmpty {
            Haptics.selection()
        }
        onRedraw?()
    }

    /// Unlocked selected objects, keyed by ID, for a move gesture.
    func movableSelection() -> [UUID: BoardObject] {
        var result: [UUID: BoardObject] = [:]
        for object in board.objects where selection.contains(object.id) && !object.isLocked {
            result[object.id] = object
        }
        return result
    }

    // MARK: Tools

    func selectTool(_ newTool: Tool) {
        if editingTextID != nil {
            endEditing()
        }
        if newTool == tool {
            if newTool.hasOptions {
                showToolOptions.toggle()
            }
        } else {
            tool = newTool
            showToolOptions = newTool.hasOptions
        }
        if newTool != .select {
            selection = []
        }
        onRedraw?()
    }

    /// Closes the tool options panel. Returns true if it was open.
    @discardableResult
    func dismissPopups() -> Bool {
        guard showToolOptions else { return false }
        showToolOptions = false
        return true
    }

    func setPenKind(_ kind: PenKind) {
        if kind != .eraser {
            lastDrawingPenKind = kind
        }
        penKind = kind
        tool = .pen
        selection = []
        onRedraw?()
    }

    /// Apple Pencil double-tap: toggle between the eraser and the last pen.
    func togglePencilEraser() {
        if tool != .pen {
            setPenKind(.pen)
            return
        }
        setPenKind(penKind == .eraser ? lastDrawingPenKind : .eraser)
    }

    var currentPenColor: PaintColor {
        penKind == .highlighter ? highlighterColor : penColor
    }

    var currentPenWidth: Double {
        switch penKind {
        case .pen: return penWidth
        case .highlighter: return highlighterWidth
        case .eraser: return eraserWidth
        }
    }

    func setPenColor(_ color: PaintColor) {
        if penKind == .highlighter {
            highlighterColor = color
        } else {
            penColor = color
        }
    }

    func setPenWidth(_ width: Double) {
        switch penKind {
        case .pen: penWidth = width
        case .highlighter: highlighterWidth = width
        case .eraser: eraserWidth = width
        }
    }

    // MARK: Freehand

    func makeStrokeObject(points: [CGPoint], pressures: [Double], id: UUID = UUID()) -> BoardObject {
        let isHighlighter = penKind == .highlighter
        let width = (isHighlighter ? highlighterWidth : penWidth) / Double(zoom)
        return BoardObject.makeStroke(worldPoints: points,
                                      pressures: isHighlighter ? [] : pressures,
                                      color: isHighlighter ? highlighterColor : penColor,
                                      width: width,
                                      isHighlighter: isHighlighter,
                                      id: id)
    }

    func addStroke(points: [CGPoint], pressures: [Double]) {
        guard !points.isEmpty, penKind != .eraser else { return }
        let stroke = makeStrokeObject(points: points, pressures: pressures)
        perform { $0.objects.append(stroke) }
    }

    /// Removes freehand strokes touched by the eraser between two points.
    func erase(from start: CGPoint, to end: CGPoint, radius: CGFloat) {
        let distance = start.distance(to: end)
        let steps = max(1, Int(ceil(distance / max(radius * 0.5, 0.5))))
        var samples: [CGPoint] = []
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            samples.append(CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        let sweep = CGRect.bounding(samples).insetBy(dx: -radius, dy: -radius)
        let hits = board.objects.filter { object in
            guard object.isStroke, !object.isLocked, object.boundingBox.intersects(sweep) else { return false }
            return samples.contains { object.hitTest($0, tolerance: radius) }
        }
        guard !hits.isEmpty else { return }
        let ids = Set(hits.map(\.id))
        recordInteractionIfNeeded()
        board.objects.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        liveChange()
    }

    // MARK: Creating objects

    func handleTap(at point: CGPoint, tolerance: CGFloat) {
        if let hit = topObject(at: point, tolerance: tolerance), !hit.isLocked {
            if tool == .text, hit.textContent != nil {
                beginEditing(hit.id)
                return
            }
            if tool == .sticky, hit.stickyContent != nil {
                beginEditing(hit.id)
                return
            }
        }
        switch tool {
        case .text: addText(at: point)
        case .sticky: addSticky(at: point)
        default: break
        }
    }

    func addText(at point: CGPoint) {
        let content = TextContent(text: "",
                                  font: lastTextFont,
                                  fontSize: Double(min(max((24 / zoom).rounded(), 4), 600)),
                                  isBold: false,
                                  isItalic: false,
                                  alignment: .left,
                                  color: .themeForeground)
        var object = BoardObject(frame: CGRect(x: point.x, y: point.y, width: 280 / zoom, height: 10),
                                 content: .text(content))
        object.fitTextHeight()
        object.frame.origin.y = point.y - object.frame.height / 2
        perform { $0.objects.append(object) }
        selection = [object.id]
        beginEditing(object.id)
    }

    func addSticky(at point: CGPoint) {
        let side = 200 / zoom
        let content = StickyContent(text: "",
                                    color: .sticky(stickyColorIndex),
                                    fontSize: Double(min(max((22 / zoom).rounded(), 4), 400)))
        let object = BoardObject(frame: CGRect(center: point, size: CGSize(width: side, height: side)),
                                 content: .sticky(content))
        perform { $0.objects.append(object) }
        selection = [object.id]
        beginEditing(object.id)
    }

    func insertImage(_ image: UIImage) {
        do {
            let imported = try imageStore.importImage(image)
            let visible = visibleWorldRect()
            let maxWidth = max(visible.width * 0.6, 40)
            let maxHeight = max(visible.height * 0.45, 40)
            let pixelWidth = max(imported.pixelSize.width, 1)
            let pixelHeight = max(imported.pixelSize.height, 1)
            let fit = min(maxWidth / pixelWidth, maxHeight / pixelHeight)
            let size = CGSize(width: pixelWidth * fit, height: pixelHeight * fit)
            let object = BoardObject(frame: CGRect(center: visible.center, size: size),
                                     content: .image(ImageContent(imageID: imported.id, opacity: 1)))
            perform { $0.objects.append(object) }
            tool = .select
            selection = [object.id]
            Haptics.light()
        } catch {
            showNotice("Couldn't add image. \(error.localizedDescription)")
        }
    }

    // MARK: Transforming objects

    func moveObjects(_ originals: [UUID: BoardObject], by delta: CGPoint) {
        guard !originals.isEmpty else { return }
        let updated: [BoardObject] = originals.values.map { original in
            var object = original
            object.frame = original.frame.offsetBy(dx: delta.x, dy: delta.y)
            return object
        }
        liveReplace(updated)
    }

    /// Resizes from a corner handle (0 top-left, 1 top-right, 2 bottom-right,
    /// 3 bottom-left). The opposite corner stays fixed, also when rotated.
    func resize(_ original: BoardObject, corner: Int, to point: CGPoint) {
        guard !original.isLocked, (0..<4).contains(corner) else { return }
        let signs: [(CGFloat, CGFloat)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        let (sx, sy) = signs[corner]
        let angle = CGFloat(original.rotation)
        let oldWidth = max(original.frame.width, 0.001)
        let oldHeight = max(original.frame.height, 0.001)
        let anchor = original.localToWorld(CGPoint(x: -sx * oldWidth / 2, y: -sy * oldHeight / 2))
        let local = (point - anchor).rotated(by: -angle)
        let minimum = 12 / zoom
        var width = max(minimum, local.x * sx)
        var height = max(minimum, local.y * sy)

        if original.keepsAspectRatio {
            let factor = max(width / oldWidth, height / oldHeight)
            width = max(minimum, oldWidth * factor)
            height = width * oldHeight / oldWidth
        }

        var object = original
        if let text = original.textContent {
            height = TextMetrics.height(for: text, width: width)
        }
        let center = anchor + CGPoint(x: sx * width / 2, y: sy * height / 2).rotated(by: angle)
        object.frame = CGRect(center: center, size: CGSize(width: width, height: height))
        liveReplace([object])
    }

    func rotate(_ original: BoardObject, toward point: CGPoint) {
        guard !original.isLocked else { return }
        let vector = point - original.center
        guard vector.length > 1 / zoom else { return }
        var angle = Double(atan2(vector.y, vector.x)) + Double.pi / 2
        let step = Double.pi / 4
        let nearest = (angle / step).rounded() * step
        let snapped = abs(angle - nearest) < 4 * Double.pi / 180
        if snapped {
            angle = nearest
        }
        if snapped && !lastRotationSnapped {
            Haptics.selection()
        }
        lastRotationSnapped = snapped
        var object = original
        object.rotation = GeometryUtils.normalizedAngle(angle)
        liveReplace([object])
    }

    // MARK: Text editing

    func beginEditing(_ id: UUID) {
        guard let object = object(withID: id), object.isEditableText, !object.isLocked else { return }
        if let current = editingTextID, current != id {
            endEditing()
        }
        tool = .select
        selection = [id]
        editingTextID = id
        history.breakCoalescing()
        revealObject(id)
        onRedraw?()
    }

    func endEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        history.breakCoalescing()
        if let object = object(withID: id),
           let text = object.textContent,
           text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            perform { board in
                board.objects.removeAll { $0.id == id }
            }
            selection.remove(id)
        }
        onRedraw?()
    }

    func setEditingText(_ text: String) {
        guard let id = editingTextID else { return }
        perform("text-\(id.uuidString)") { board in
            if let index = board.objects.firstIndex(where: { $0.id == id }) {
                board.objects[index].setTextValue(text)
            }
        }
    }

    /// Pans so an object being edited sits in the upper part of the screen,
    /// above the keyboard.
    private func revealObject(_ id: UUID) {
        guard let object = object(withID: id), viewSize.width > 0, viewSize.height > 0 else { return }
        let screen = viewport.toScreen(object.center)
        let needsVertical = screen.y > viewSize.height * 0.42 || screen.y < 80
        let needsHorizontal = screen.x < 20 || screen.x > viewSize.width - 20
        guard needsVertical || needsHorizontal else { return }
        if needsVertical {
            viewport.offsetY += Double(viewSize.height * 0.28 - screen.y)
        }
        if needsHorizontal {
            viewport.offsetX += Double(viewSize.width / 2 - screen.x)
        }
        viewportDidChange()
        onRedraw?()
    }

    // MARK: Selection commands

    func duplicateSelection() {
        let selected = board.objects.filter { selection.contains($0.id) }
        guard !selected.isEmpty else { return }
        var idMap: [UUID: UUID] = [:]
        for object in selected {
            idMap[object.id] = UUID()
        }
        let offset = 24 / zoom
        let copies: [BoardObject] = selected.map { original in
            var copy = original
            copy.id = idMap[original.id] ?? UUID()
            copy.isLocked = false
            copy.frame = original.frame.offsetBy(dx: offset, dy: offset)
            return copy
        }
        perform { $0.objects.append(contentsOf: copies) }
        selection = Set(copies.map(\.id))
        onRedraw?()
    }

    func deleteSelection() {
        let ids = Set(board.objects.filter { selection.contains($0.id) && !$0.isLocked }.map(\.id))
        guard !ids.isEmpty else { return }
        if let editing = editingTextID, ids.contains(editing) {
            editingTextID = nil
        }
        perform { board in
            board.objects.removeAll { ids.contains($0.id) }
        }
        selection.subtract(ids)
        Haptics.medium()
        onRedraw?()
    }

    func bringForward() {
        let ids = selection
        guard !ids.isEmpty else { return }
        perform { board in
            var objects = board.objects
            guard objects.count > 1 else { return }
            for index in stride(from: objects.count - 2, through: 0, by: -1)
            where ids.contains(objects[index].id) && !ids.contains(objects[index + 1].id) {
                objects.swapAt(index, index + 1)
            }
            board.objects = objects
        }
    }

    func sendBackward() {
        let ids = selection
        guard !ids.isEmpty else { return }
        perform { board in
            var objects = board.objects
            guard objects.count > 1 else { return }
            for index in 1..<objects.count
            where ids.contains(objects[index].id) && !ids.contains(objects[index - 1].id) {
                objects.swapAt(index, index - 1)
            }
            board.objects = objects
        }
    }

    var selectionIsLocked: Bool {
        let selected = selectedObjects
        return !selected.isEmpty && selected.allSatisfy(\.isLocked)
    }

    func toggleLock() {
        let ids = selection
        guard !ids.isEmpty else { return }
        let lock = !selectionIsLocked
        if lock, let editing = editingTextID, ids.contains(editing) {
            endEditing()
        }
        perform { board in
            for index in board.objects.indices where ids.contains(board.objects[index].id) {
                board.objects[index].isLocked = lock
            }
        }
        Haptics.light()
    }

    // MARK: Property editing

    private func updateSelected(_ key: String, _ transform: (inout BoardObject) -> Void) {
        let ids = selection
        guard !ids.isEmpty else { return }
        let coalescingKey = key + "|" + ids.map(\.uuidString).sorted().joined(separator: ",")
        perform(coalescingKey) { board in
            for index in board.objects.indices
            where ids.contains(board.objects[index].id) && !board.objects[index].isLocked {
                transform(&board.objects[index])
            }
        }
    }

    func setFont(_ font: FontFamily) {
        lastTextFont = font
        updateSelected("font") { object in
            object.modifyText { $0.font = font }
        }
    }

    func setFontSize(_ size: Double) {
        updateSelected("font-size") { object in
            object.modifyText { $0.fontSize = size }
            object.modifySticky { $0.fontSize = size }
        }
    }

    func setBold(_ bold: Bool) {
        updateSelected("bold") { object in
            object.modifyText { $0.isBold = bold }
        }
    }

    func setItalic(_ italic: Bool) {
        updateSelected("italic") { object in
            object.modifyText { $0.isItalic = italic }
        }
    }

    func setAlignment(_ alignment: TextAlign) {
        updateSelected("alignment") { object in
            object.modifyText { $0.alignment = alignment }
        }
    }

    func setTextColor(_ color: PaintColor) {
        updateSelected("text-color") { object in
            object.modifyText { $0.color = color }
        }
    }

    func setStrokeColor(_ color: PaintColor) {
        updateSelected("stroke-color") { object in
            object.modifyStroke { $0.color = color }
        }
    }

    func setStrokeWidth(_ width: Double) {
        updateSelected("stroke-width") { object in
            object.modifyStroke { $0.width = width }
        }
    }

    func setStickyColor(_ index: Int) {
        stickyColorIndex = index
        updateSelected("sticky-color") { object in
            object.modifySticky { $0.color = .sticky(index) }
        }
    }

    func setOpacity(_ opacity: Double) {
        updateSelected("opacity") { object in
            object.modifyImage { $0.opacity = opacity }
        }
    }

    // MARK: Board settings

    func setTheme(_ id: ThemeID) {
        guard id != board.themeID else { return }
        perform { board in
            board.themeID = id
            if id == .blueprint && board.pattern == .none {
                board.pattern = .grid
            }
        }
    }

    func setPattern(_ pattern: BackgroundPattern) {
        guard pattern != board.pattern else { return }
        perform { $0.pattern = pattern }
    }

    func renameBoard(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != board.name else { return }
        board.name = trimmed
        commitChange()
    }

    // MARK: Undo

    func undo() {
        if editingTextID != nil {
            endEditing()
        }
        guard let previous = history.undo(current: snapshot()) else { return }
        apply(previous)
        commitChange()
    }

    func redo() {
        if editingTextID != nil {
            endEditing()
        }
        guard let next = history.redo(current: snapshot()) else { return }
        apply(next)
        commitChange()
    }

    // MARK: Viewport

    func viewportDidChange() {
        board.viewport = viewport
        autosave.scheduleSave()
    }

    // MARK: Export

    func export(format: ExportFormat, selectionOnly: Bool) {
        let objects = selectionOnly ? board.objects.filter { selection.contains($0.id) } : board.objects
        do {
            let url = try exportService.export(objects: objects,
                                               board: board,
                                               format: format,
                                               fallbackRect: visibleWorldRect(),
                                               nameSuffix: selectionOnly ? " Selection" : "")
            shareItem = ShareItem(url: url)
        } catch {
            showNotice("Export failed. \(error.localizedDescription)")
        }
    }

    // MARK: Persistence

    private func boardForSaving() -> Board {
        var copy = board
        copy.viewport = viewport
        return copy
    }

    func flushSave() {
        board.viewport = viewport
        autosave.flush(synchronously: true)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if editingTextID != nil {
            endEditing()
        }
        flushSave()
        NotificationCenter.default.post(name: .slateBoardsDidChange, object: nil)
    }

    func reopen() {
        isClosed = false
    }

    private func handleSaveResult(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            storageWarning = store.isStorageLow ? "Storage is almost full. Free up space to keep saving." : nil
        case .failure(let error):
            if let storageError = error as? StorageError, storageError == .lowStorage {
                storageWarning = "Not enough storage to save. Your changes are kept and will save once space is freed."
            } else {
                storageWarning = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }

    func showNotice(_ message: String) {
        noticeMessage = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            if self?.noticeMessage == message {
                self?.noticeMessage = nil
            }
        }
    }
}
