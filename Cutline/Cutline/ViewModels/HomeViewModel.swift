import Observation
import PhotosUI
import SwiftUI

/// Project list, search, templates and the pending import for new projects.
@MainActor
@Observable
final class HomeViewModel {
    private(set) var projects: [ProjectSummary] = []
    var searchText = ""
    var alert: AlertMessage?

    /// Picked media waiting to be imported by a freshly opened editor.
    @ObservationIgnored var pendingImports: [UUID: [PhotosPickerItem]] = [:]

    private let store = ProjectStore.shared

    var filteredProjects: [ProjectSummary] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func reload() {
        let result = store.listProjects()
        projects = result.summaries
        var notes: [String] = []
        if !result.recovered.isEmpty {
            notes.append("Recovered \(result.recovered.joined(separator: ", ")) from a backup after an unexpected shutdown.")
        }
        if result.damagedCount > 0 {
            notes.append("\(result.damagedCount) damaged project\(result.damagedCount == 1 ? "" : "s") couldn't be opened.")
        }
        if !notes.isEmpty {
            alert = AlertMessage(title: "Projects Recovered", message: notes.joined(separator: "\n\n"))
        }
    }

    /// Creates a project and stores the picked media for the editor to import.
    func createProject(aspect: AspectRatio, items: [PhotosPickerItem]) -> UUID? {
        do {
            let project = try store.createProject(name: nextName(), aspect: aspect)
            if !items.isEmpty {
                pendingImports[project.id] = items
            }
            reload()
            Haptics.light()
            return project.id
        } catch {
            alert = AlertMessage(title: "Couldn't Create Project", message: error.localizedDescription)
            return nil
        }
    }

    func takePendingImports(for id: UUID) -> [PhotosPickerItem] {
        pendingImports.removeValue(forKey: id) ?? []
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.rename(id: id, to: trimmed)
        } catch {
            alert = AlertMessage(title: "Couldn't Rename", message: error.localizedDescription)
        }
        reload()
    }

    func duplicate(_ id: UUID) {
        do {
            _ = try store.duplicate(id: id)
        } catch {
            alert = AlertMessage(title: "Couldn't Duplicate", message: error.localizedDescription)
        }
        reload()
    }

    func delete(_ id: UUID) {
        store.delete(id: id)
        Haptics.medium()
        reload()
    }

    private func nextName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let base = "Project \(formatter.string(from: Date()))"
        let names = Set(projects.map(\.name))
        if !names.contains(base) { return base }
        var index = 2
        while names.contains("\(base) (\(index))") {
            index += 1
        }
        return "\(base) (\(index))"
    }
}
