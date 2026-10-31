import Foundation

/// A whiteboard document. Saved as one JSON file per board.
struct Board: Codable, Identifiable {
    static let currentVersion = 1

    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var themeID: ThemeID
    var pattern: BackgroundPattern
    var viewport: Viewport
    var objects: [BoardObject]
    var version: Int

    init(id: UUID = UUID(),
         name: String,
         themeID: ThemeID = .dark,
         pattern: BackgroundPattern = .dots) {
        let now = Date()
        self.id = id
        self.name = name
        self.createdAt = now
        self.updatedAt = now
        self.themeID = themeID
        self.pattern = pattern
        self.viewport = Viewport()
        self.objects = []
        self.version = Board.currentVersion
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case updatedAt
        case themeID
        case pattern
        case viewport
        case objects
        case version
    }

    /// Tolerant decoding: missing or damaged fields fall back to defaults and
    /// individual damaged objects are dropped instead of failing the board.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? "Untitled"
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? createdAt
        themeID = (try? container.decode(ThemeID.self, forKey: .themeID)) ?? .dark
        pattern = (try? container.decode(BackgroundPattern.self, forKey: .pattern)) ?? .none
        let decodedViewport = (try? container.decode(Viewport.self, forKey: .viewport)) ?? Viewport()
        viewport = decodedViewport.isValid ? decodedViewport : Viewport()
        let wrapped = (try? container.decode([LossyDecodable<BoardObject>].self, forKey: .objects)) ?? []
        objects = wrapped.compactMap { $0.value }
        version = (try? container.decode(Int.self, forKey: .version)) ?? Board.currentVersion
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(themeID, forKey: .themeID)
        try container.encode(pattern, forKey: .pattern)
        try container.encode(viewport, forKey: .viewport)
        try container.encode(objects, forKey: .objects)
        try container.encode(version, forKey: .version)
    }

    var referencedImageIDs: Set<String> {
        Set(objects.compactMap { $0.imageContent?.imageID })
    }
}

/// Lightweight listing information for the home screen.
struct BoardHeader: Decodable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var updatedAt: Date
    var themeID: ThemeID

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case updatedAt
        case themeID
    }

    init(board: Board) {
        id = board.id
        name = board.name
        updatedAt = board.updatedAt
        themeID = board.themeID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? "Untitled"
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? .distantPast
        themeID = (try? container.decode(ThemeID.self, forKey: .themeID)) ?? .dark
    }
}

/// Decodes a value, yielding nil instead of throwing when the element is damaged.
struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// The undoable part of a board.
struct BoardSnapshot: Equatable {
    var objects: [BoardObject]
    var themeID: ThemeID
    var pattern: BackgroundPattern
}
