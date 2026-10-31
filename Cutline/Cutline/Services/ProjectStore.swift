import Foundation
import UIKit

enum StoreError: LocalizedError, Equatable {
    case lowStorage
    case unreadable
    case missingProject

    var errorDescription: String? {
        switch self {
        case .lowStorage:
            return "Your iPhone is almost out of storage. Free up some space and try again."
        case .unreadable:
            return "This project's file is damaged and no backup could be restored."
        case .missingProject:
            return "This project no longer exists."
        }
    }
}

extension Notification.Name {
    static let cutlineProjectsDidChange = Notification.Name("CutlineProjectsDidChange")
}

/// Stores each project in its own folder:
///
///     Documents/Cutline/Projects/<id>/project.json      the project
///     Documents/Cutline/Projects/<id>/project.json.bak  last copy that opened cleanly
///     Documents/Cutline/Projects/<id>/media/            imported and generated media
///     Documents/Cutline/Projects/<id>/thumbnail.jpg     home screen preview
final class ProjectStore: @unchecked Sendable {
    static let shared = ProjectStore()

    static let minimumFreeBytes: Int64 = 50 * 1024 * 1024

    let rootURL: URL
    private let fileManager = FileManager.default

    private init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        rootURL = documents.appendingPathComponent("Cutline/Projects", isDirectory: true)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func directory(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func mediaDirectory(for id: UUID) -> URL {
        let url = directory(for: id).appendingPathComponent("media", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func mediaURL(projectID: UUID, fileName: String) -> URL {
        mediaDirectory(for: projectID).appendingPathComponent(fileName)
    }

    func projectURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("project.json")
    }

    func backupURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("project.json.bak")
    }

    func thumbnailURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("thumbnail.jpg")
    }

    // MARK: Listing

    struct ListResult {
        var summaries: [ProjectSummary]
        var recovered: [String]
        var damagedCount: Int
    }

    func listProjects() -> ListResult {
        let folders = (try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        var summaries: [ProjectSummary] = []
        var recovered: [String] = []
        var damaged = 0
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            do {
                let result = try loadProject(id: id)
                let project = result.project
                if result.recovered { recovered.append(project.name) }
                summaries.append(ProjectSummary(id: project.id, name: project.name, updatedAt: project.updatedAt,
                                                aspect: project.canvas.aspect, duration: project.duration))
            } catch {
                damaged += 1
            }
        }
        summaries.sort { $0.updatedAt > $1.updatedAt }
        return ListResult(summaries: summaries, recovered: recovered, damagedCount: damaged)
    }

    // MARK: Load and save

    /// Loads a project, falling back to the last good backup if the main file
    /// is damaged (for example after a crash during a write).
    func loadProject(id: UUID) throws -> (project: Project, recovered: Bool) {
        let decoder = JSONDecoder()
        let url = projectURL(for: id)
        guard fileManager.fileExists(atPath: directory(for: id).path) else { throw StoreError.missingProject }
        if let data = try? Data(contentsOf: url), var project = try? decoder.decode(Project.self, from: data) {
            project.id = id
            try? data.write(to: backupURL(for: id), options: .atomic)
            return (project, false)
        }
        if let data = try? Data(contentsOf: backupURL(for: id)), var project = try? decoder.decode(Project.self, from: data) {
            project.id = id
            if fileManager.fileExists(atPath: url.path) {
                let damagedURL = directory(for: id).appendingPathComponent("project-damaged-\(Int(Date().timeIntervalSince1970)).json")
                try? fileManager.moveItem(at: url, to: damagedURL)
            }
            try? data.write(to: url, options: .atomic)
            return (project, true)
        }
        throw StoreError.unreadable
    }

    func encode(_ project: Project) throws -> Data {
        try JSONEncoder().encode(project)
    }

    func write(_ data: Data, projectID: UUID) throws {
        try ensureSpace(bytes: Int64(data.count))
        try fileManager.createDirectory(at: directory(for: projectID), withIntermediateDirectories: true)
        do {
            try data.write(to: projectURL(for: projectID), options: .atomic)
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw StoreError.lowStorage
        }
    }

    func save(_ project: Project) throws {
        try write(try encode(project), projectID: project.id)
    }

    func saveThumbnail(_ data: Data, projectID: UUID) {
        try? data.write(to: thumbnailURL(for: projectID), options: .atomic)
    }

    // MARK: Management

    func createProject(name: String, aspect: AspectRatio) throws -> Project {
        try ensureSpace(bytes: 1_000_000)
        var project = Project(name: name)
        project.canvas.aspect = aspect
        try fileManager.createDirectory(at: directory(for: project.id), withIntermediateDirectories: true)
        _ = mediaDirectory(for: project.id)
        try save(project)
        return project
    }

    func rename(id: UUID, to name: String) throws {
        var project = try loadProject(id: id).project
        project.name = name
        project.updatedAt = Date()
        try save(project)
    }

    func duplicate(id: UUID) throws -> Project {
        var project = try loadProject(id: id).project
        let size = folderSize(directory(for: id))
        try ensureSpace(bytes: size)
        let newID = UUID()
        try fileManager.copyItem(at: directory(for: id), to: directory(for: newID))
        project.id = newID
        project.name += " Copy"
        project.createdAt = Date()
        project.updatedAt = Date()
        try save(project)
        return project
    }

    func delete(id: UUID) {
        try? fileManager.removeItem(at: directory(for: id))
    }

    // MARK: Storage

    func availableCapacity() -> Int64? {
        let values = try? rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func ensureSpace(bytes: Int64) throws {
        guard let available = availableCapacity() else { return }
        if available < bytes + ProjectStore.minimumFreeBytes {
            throw StoreError.lowStorage
        }
    }

    func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
