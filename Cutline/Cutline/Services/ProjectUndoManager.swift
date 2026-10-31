import Foundation

/// Snapshot-based undo/redo with unlimited history for the editing session.
/// Changes that share a coalescing key within a short window (slider drags,
/// typing) collapse into a single step.
final class ProjectUndoManager {
    static let coalescingInterval: TimeInterval = 1.0

    private(set) var undoStack: [(content: ProjectContent, label: String)] = []
    private(set) var redoStack: [(content: ProjectContent, label: String)] = []
    private var lastKey: String?
    private var lastDate = Date.distantPast

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }

    @discardableResult
    func record(_ content: ProjectContent, label: String, coalescingKey: String? = nil) -> Bool {
        let now = Date()
        if let key = coalescingKey, key == lastKey, now.timeIntervalSince(lastDate) < ProjectUndoManager.coalescingInterval {
            lastDate = now
            return false
        }
        undoStack.append((content, label))
        redoStack.removeAll()
        lastKey = coalescingKey
        lastDate = now
        return true
    }

    func undo(current: ProjectContent) -> (content: ProjectContent, label: String)? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append((current, entry.label))
        lastKey = nil
        return entry
    }

    func redo(current: ProjectContent) -> (content: ProjectContent, label: String)? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append((current, entry.label))
        lastKey = nil
        return entry
    }

    func discardLast() {
        _ = undoStack.popLast()
        lastKey = nil
    }

    func breakCoalescing() {
        lastKey = nil
    }
}
