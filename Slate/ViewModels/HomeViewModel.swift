import Foundation
import Observation

/// Lists, creates, renames, duplicates and deletes boards.
@MainActor
@Observable
final class HomeViewModel {
    private(set) var boards: [BoardHeader] = []
    var alertMessage: String?

    private let store: BoardStore

    init(store: BoardStore = .shared) {
        self.store = store
    }

    func reload() {
        let result = store.listBoards()
        boards = result.headers
        var messages: [String] = []
        if !result.recoveredNames.isEmpty {
            messages.append("Recovered \(result.recoveredNames.joined(separator: ", ")) from a backup after its file was damaged.")
        }
        if result.quarantinedCount > 0 {
            let noun = result.quarantinedCount == 1 ? "board file was" : "board files were"
            messages.append("\(result.quarantinedCount) damaged \(noun) moved to the Recovered folder.")
        }
        if !messages.isEmpty {
            alertMessage = messages.joined(separator: "\n\n")
        }
    }

    func createBoard() -> UUID? {
        do {
            let board = try store.createBoard(name: nextBoardName(), themeID: ThemeManager.shared.defaultThemeID)
            reload()
            Haptics.light()
            return board.id
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.rename(id: id, to: trimmed)
            reload()
        } catch {
            alertMessage = error.localizedDescription
            reload()
        }
    }

    func duplicate(_ id: UUID) {
        do {
            _ = try store.duplicate(id: id)
            reload()
        } catch {
            alertMessage = error.localizedDescription
            reload()
        }
    }

    func delete(_ id: UUID) {
        store.delete(id: id)
        Haptics.medium()
        reload()
    }

    private func nextBoardName() -> String {
        let existing = Set(boards.map(\.name))
        if !existing.contains("Untitled Board") {
            return "Untitled Board"
        }
        var index = 2
        while existing.contains("Untitled Board \(index)") {
            index += 1
        }
        return "Untitled Board \(index)"
    }
}
