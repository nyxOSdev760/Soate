import Foundation

enum StorageError: LocalizedError, Equatable {
    case lowStorage
    case unreadable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .lowStorage:
            return "Your device is almost out of storage. Free up space so Slate can save."
        case .unreadable:
            return "This board's file is damaged and couldn't be opened. It was moved to the Recovered folder."
        case .encodingFailed:
            return "The board couldn't be prepared for saving."
        }
    }
}

extension Notification.Name {
    static let slateBoardsDidChange = Notification.Name("SlateBoardsDidChange")
}

/// File-system persistence. Layout inside Documents:
///
///     Slate/Boards/<id>.json        board documents
///     Slate/Boards/<id>.json.bak    last copy that opened cleanly
///     Slate/Images/<id>.jpg|png     imported images referenced by ID
///     Slate/Thumbnails/<id>.jpg     home screen previews
///     Slate/Recovered/              damaged files moved aside
final class BoardStore: @unchecked Sendable {
    static let shared = BoardStore()

    /// Saving is refused when free space would drop below this.
    static let minimumFreeBytes: Int64 = 5 * 1024 * 1024
    /// A warning is shown when free space drops below this.
    static let lowStorageWarningBytes: Int64 = 100 * 1024 * 1024

    let rootURL: URL
    private let fileManager = FileManager.default

    var boardsURL: URL { rootURL.appendingPathComponent("Boards", isDirectory: true) }
    var imagesURL: URL { rootURL.appendingPathComponent("Images", isDirectory: true) }
    var thumbnailsURL: URL { rootURL.appendingPathComponent("Thumbnails", isDirectory: true) }
    var recoveredURL: URL { rootURL.appendingPathComponent("Recovered", isDirectory: true) }

    private init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        rootURL = documents.appendingPathComponent("Slate", isDirectory: true)
        prepareDirectories()
    }

    func prepareDirectories() {
        for url in [rootURL, boardsURL, imagesURL, thumbnailsURL] {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func boardURL(for id: UUID) -> URL {
        boardsURL.appendingPathComponent("\(id.uuidString).json")
    }

    func backupURL(for id: UUID) -> URL {
        boardsURL.appendingPathComponent("\(id.uuidString).json.bak")
    }

    func thumbnailURL(for id: UUID) -> URL {
        thumbnailsURL.appendingPathComponent("\(id.uuidString).jpg")
    }

    private func makeEncoder() -> JSONEncoder {
        JSONEncoder()
    }

    private func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    // MARK: Listing

    struct ListResult {
        var headers: [BoardHeader]
        var recoveredNames: [String]
        var quarantinedCount: Int
    }

    func listBoards() -> ListResult {
        prepareDirectories()
        let files = (try? fileManager.contentsOfDirectory(at: boardsURL, includingPropertiesForKeys: nil)) ?? []
        var headers: [BoardHeader] = []
        var recovered: [String] = []
        var quarantined = 0
        let decoder = makeDecoder()

        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let header = try? decoder.decode(BoardHeader.self, from: data) {
                headers.append(header)
                continue
            }
            let backup = url.appendingPathExtension("bak")
            if let data = try? Data(contentsOf: backup),
               let header = try? decoder.decode(BoardHeader.self, from: data) {
                quarantine(url)
                try? data.write(to: url, options: .atomic)
                headers.append(header)
                recovered.append(header.name)
                continue
            }
            quarantine(url)
            quarantined += 1
        }

        headers.sort { $0.updatedAt > $1.updatedAt }
        return ListResult(headers: headers, recoveredNames: recovered, quarantinedCount: quarantined)
    }

    // MARK: Loading

    /// Loads a board. Falls back to the last-known-good backup if the main
    /// file is damaged, and moves unrecoverable files aside.
    func loadBoard(id: UUID) throws -> (board: Board, recovered: Bool) {
        let url = boardURL(for: id)
        let decoder = makeDecoder()
        if let data = try? Data(contentsOf: url),
           let board = try? decoder.decode(Board.self, from: data) {
            try? data.write(to: backupURL(for: id), options: .atomic)
            return (board, false)
        }
        if let data = try? Data(contentsOf: backupURL(for: id)),
           let board = try? decoder.decode(Board.self, from: data) {
            if fileManager.fileExists(atPath: url.path) {
                quarantine(url)
            }
            try? data.write(to: url, options: .atomic)
            return (board, true)
        }
        if fileManager.fileExists(atPath: url.path) {
            quarantine(url)
        }
        throw StorageError.unreadable
    }

    // MARK: Saving

    func encode(_ board: Board) throws -> Data {
        do {
            return try makeEncoder().encode(board)
        } catch {
            throw StorageError.encodingFailed
        }
    }

    func write(_ data: Data, for id: UUID) throws {
        try ensureSpace(for: Int64(data.count))
        prepareDirectories()
        do {
            try data.write(to: boardURL(for: id), options: .atomic)
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw StorageError.lowStorage
        }
    }

    func save(_ board: Board) throws {
        try write(try encode(board), for: board.id)
    }

    func saveThumbnail(_ data: Data, for id: UUID) {
        guard (try? ensureSpace(for: Int64(data.count))) != nil else { return }
        try? data.write(to: thumbnailURL(for: id), options: .atomic)
    }

    func availableCapacity() -> Int64? {
        let values = try? rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    var isStorageLow: Bool {
        guard let available = availableCapacity() else { return false }
        return available < BoardStore.lowStorageWarningBytes
    }

    func ensureSpace(for bytes: Int64) throws {
        guard let available = availableCapacity() else { return }
        if available < bytes + BoardStore.minimumFreeBytes {
            throw StorageError.lowStorage
        }
    }

    // MARK: Board management

    func createBoard(name: String, themeID: ThemeID) throws -> Board {
        let theme = ThemeManager.shared.theme(for: themeID)
        let board = Board(name: name, themeID: themeID, pattern: theme.preferredPattern)
        try save(board)
        return board
    }

    func rename(id: UUID, to name: String) throws {
        var board = try loadBoard(id: id).board
        board.name = name
        board.updatedAt = Date()
        try save(board)
    }

    func duplicate(id: UUID) throws -> Board {
        let original = try loadBoard(id: id).board
        var copy = original
        copy.id = UUID()
        copy.name = original.name + " Copy"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        try save(copy)
        if let thumbnail = try? Data(contentsOf: thumbnailURL(for: id)) {
            saveThumbnail(thumbnail, for: copy.id)
        }
        return copy
    }

    func delete(id: UUID) {
        try? fileManager.removeItem(at: boardURL(for: id))
        try? fileManager.removeItem(at: backupURL(for: id))
        try? fileManager.removeItem(at: thumbnailURL(for: id))
    }

    private func quarantine(_ url: URL) {
        try? fileManager.createDirectory(at: recoveredURL, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = recoveredURL.appendingPathComponent("\(stamp)-\(url.lastPathComponent)")
        if (try? fileManager.moveItem(at: url, to: destination)) == nil {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: Image garbage collection

    /// Removes image files no board references. Runs at launch, in the
    /// background, and never touches files created in the last few minutes.
    func collectUnusedImagesInBackground(imageStore: ImageStore) {
        let startedAt = Date()
        DispatchQueue.global(qos: .utility).async { [self] in
            let files = (try? fileManager.contentsOfDirectory(at: boardsURL, includingPropertiesForKeys: nil)) ?? []
            var referenced = Set<String>()
            let decoder = makeDecoder()
            for url in files where url.pathExtension == "json" || url.pathExtension == "bak" {
                guard let data = try? Data(contentsOf: url) else { continue }
                guard let board = try? decoder.decode(Board.self, from: data) else {
                    // An unreadable board might still reference images: keep everything.
                    return
                }
                referenced.formUnion(board.referencedImageIDs)
            }
            imageStore.removeImages(notIn: referenced, olderThan: startedAt.addingTimeInterval(-300))
        }
    }
}
