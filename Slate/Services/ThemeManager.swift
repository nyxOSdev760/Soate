import Foundation

/// Owns the built-in whiteboard themes.
final class ThemeManager {
    static let shared = ThemeManager()

    let defaultThemeID: ThemeID = .dark
    let themes: [Theme]
    private let lookup: [ThemeID: Theme]

    private init() {
        let all = ThemeID.allCases.map { ThemeManager.makeTheme($0) }
        themes = all
        var table: [ThemeID: Theme] = [:]
        for theme in all {
            table[theme.id] = theme
        }
        lookup = table
    }

    func theme(for id: ThemeID) -> Theme {
        lookup[id] ?? ThemeManager.makeTheme(.dark)
    }

    private static func makeTheme(_ id: ThemeID) -> Theme {
        switch id {
        case .dark:
            return Theme(id: .dark,
                         name: "Dark",
                         background: RGBA(hex: 0x121214),
                         foreground: RGBA(hex: 0xF2F2F7),
                         patternColor: RGBA(1, 1, 1, 0.11),
                         stickyPalette: [RGBA(hex: 0xFFE066), RGBA(hex: 0xFF9EB5), RGBA(hex: 0x9BE89B),
                                         RGBA(hex: 0x8EC5FF), RGBA(hex: 0xFFB86B), RGBA(hex: 0xC9A7FF)],
                         stickyText: RGBA(hex: 0x1C1C1E),
                         accent: RGBA(hex: 0x0A84FF),
                         isDark: true,
                         preferredPattern: .dots)
        case .light:
            return Theme(id: .light,
                         name: "Light",
                         background: RGBA(hex: 0xFAFAFA),
                         foreground: RGBA(hex: 0x1C1C1E),
                         patternColor: RGBA(0, 0, 0, 0.12),
                         stickyPalette: [RGBA(hex: 0xFFF08A), RGBA(hex: 0xFFC2D1), RGBA(hex: 0xBDF2C0),
                                         RGBA(hex: 0xC3E0FF), RGBA(hex: 0xFFD6A5), RGBA(hex: 0xE0CCFF)],
                         stickyText: RGBA(hex: 0x1C1C1E),
                         accent: RGBA(hex: 0x007AFF),
                         isDark: false,
                         preferredPattern: .dots)
        case .blackboard:
            return Theme(id: .blackboard,
                         name: "Blackboard",
                         background: RGBA(hex: 0x1E3B2F),
                         foreground: RGBA(hex: 0xF3F0E6),
                         patternColor: RGBA(1, 1, 1, 0.08),
                         stickyPalette: [RGBA(hex: 0xF7E7A1), RGBA(hex: 0xF5B8C4), RGBA(hex: 0xC5E8B7),
                                         RGBA(hex: 0xB5D6F2), RGBA(hex: 0xF7C99B), RGBA(hex: 0xD9C6F0)],
                         stickyText: RGBA(hex: 0x1F2A24),
                         accent: RGBA(hex: 0xFFD60A),
                         isDark: true,
                         preferredPattern: .none)
        case .blueprint:
            return Theme(id: .blueprint,
                         name: "Blueprint",
                         background: RGBA(hex: 0x0E2A5C),
                         foreground: RGBA(hex: 0xE6F0FF),
                         patternColor: RGBA(hex: 0x8FB8FF, alpha: 0.28),
                         stickyPalette: [RGBA(hex: 0xFFF3B0), RGBA(hex: 0xFFC9DE), RGBA(hex: 0xC8F7DC),
                                         RGBA(hex: 0xD6E8FF), RGBA(hex: 0xFFDDB5), RGBA(hex: 0xE5D8FF)],
                         stickyText: RGBA(hex: 0x0E2A5C),
                         accent: RGBA(hex: 0x64D2FF),
                         isDark: true,
                         preferredPattern: .grid)
        case .paper:
            return Theme(id: .paper,
                         name: "Paper",
                         background: RGBA(hex: 0xF6F1E7),
                         foreground: RGBA(hex: 0x2B2620),
                         patternColor: RGBA(hex: 0x8C7B60, alpha: 0.2),
                         stickyPalette: [RGBA(hex: 0xFCE38A), RGBA(hex: 0xF8B4B4), RGBA(hex: 0xB8E0B0),
                                         RGBA(hex: 0xAFCFEA), RGBA(hex: 0xF5C08E), RGBA(hex: 0xD3BFE8)],
                         stickyText: RGBA(hex: 0x2B2620),
                         accent: RGBA(hex: 0xC2410C),
                         isDark: false,
                         preferredPattern: .lines)
        case .midnight:
            return Theme(id: .midnight,
                         name: "Midnight",
                         background: RGBA(hex: 0x181A3D),
                         foreground: RGBA(hex: 0xE8E6FF),
                         patternColor: RGBA(hex: 0xA5A0FF, alpha: 0.16),
                         stickyPalette: [RGBA(hex: 0xFFE38F), RGBA(hex: 0xFFA8C9), RGBA(hex: 0xA8F0D1),
                                         RGBA(hex: 0xA8C8FF), RGBA(hex: 0xFFC48F), RGBA(hex: 0xD4B8FF)],
                         stickyText: RGBA(hex: 0x181A3D),
                         accent: RGBA(hex: 0xA78BFA),
                         isDark: true,
                         preferredPattern: .dots)
        case .graphite:
            return Theme(id: .graphite,
                         name: "Graphite",
                         background: RGBA(hex: 0x2B2D31),
                         foreground: RGBA(hex: 0xEDEDED),
                         patternColor: RGBA(1, 1, 1, 0.1),
                         stickyPalette: [RGBA(hex: 0xF2DC7C), RGBA(hex: 0xF0A3B5), RGBA(hex: 0xA6DDA6),
                                         RGBA(hex: 0x9CC4F0), RGBA(hex: 0xF2B880), RGBA(hex: 0xC8B2F0)],
                         stickyText: RGBA(hex: 0x202124),
                         accent: RGBA(hex: 0x0A84FF),
                         isDark: true,
                         preferredPattern: .dots)
        }
    }
}
