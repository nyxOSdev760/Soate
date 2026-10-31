import Foundation

enum ThemeID: String, Codable, CaseIterable, Identifiable {
    case dark
    case light
    case blackboard
    case blueprint
    case paper
    case midnight
    case graphite

    var id: String { rawValue }
}

enum BackgroundPattern: String, Codable, CaseIterable, Identifiable {
    case none
    case dots
    case grid
    case lines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .dots: return "Dots"
        case .grid: return "Grid"
        case .lines: return "Lines"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "square"
        case .dots: return "circle.grid.3x3"
        case .grid: return "grid"
        case .lines: return "line.3.horizontal"
        }
    }
}

/// A whiteboard theme. Defines the canvas background, the default stroke and
/// text color, the background pattern color and the sticky note palette.
struct Theme: Codable, Identifiable, Equatable {
    let id: ThemeID
    let name: String
    let background: RGBA
    let foreground: RGBA
    let patternColor: RGBA
    let stickyPalette: [RGBA]
    let stickyText: RGBA
    let accent: RGBA
    let isDark: Bool
    let preferredPattern: BackgroundPattern
}
