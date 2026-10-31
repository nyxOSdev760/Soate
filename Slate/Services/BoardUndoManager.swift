import Foundation

/// Snapshot-based undo/redo with unlimited history for the session.
/// Rapid changes sharing a coalescing key (typing, slider drags) collapse into
/// a single undo step.
final class BoardUndoManager {
    static let coalescingInterval: TimeInterval = 1.0

    private(set) var undoStack: [BoardSnapshot] = []
    private(set) var redoStack: [BoardSnapshot] = []
    private var lastCoalescingKey: String?
    private var lastRecordDate = Date.distantPast

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Records the state before a change. Returns true when a new undo step
    /// was pushed (false when coalesced into the previous step).
    @discardableResult
    func record(_ snapshot: BoardSnapshot, coalescingKey: String? = nil) -> Bool {
        let now = Date()
        if let key = coalescingKey,
           key == lastCoalescingKey,
           now.timeIntervalSince(lastRecordDate) < BoardUndoManager.coalescingInterval {
            lastRecordDate = now
            return false
        }
        undoStack.append(snapshot)
        redoStack.removeAll()
        lastCoalescingKey = coalescingKey
        lastRecordDate = now
        return true
    }

    func undo(current: BoardSnapshot) -> BoardSnapshot? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        breakCoalescing()
        return previous
    }

    func redo(current: BoardSnapshot) -> BoardSnapshot? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        breakCoalescing()
        return next
    }

    /// Removes the most recent undo step (used when a change is cancelled or
    /// turned out to be a no-op).
    func discardLast() {
        _ = undoStack.popLast()
        breakCoalescing()
    }

    func breakCoalescing() {
        lastCoalescingKey = nil
    }
}
