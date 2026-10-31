import CoreGraphics
import Foundation

enum AspectRatio: String, Codable, CaseIterable, Identifiable {
    case vertical = "9:16"
    case square = "1:1"
    case portrait = "4:5"
    case widescreen = "16:9"

    var id: String { rawValue }

    var ratio: CGSize {
        switch self {
        case .vertical: return CGSize(width: 9, height: 16)
        case .square: return CGSize(width: 1, height: 1)
        case .portrait: return CGSize(width: 4, height: 5)
        case .widescreen: return CGSize(width: 16, height: 9)
        }
    }

    var title: String {
        switch self {
        case .vertical: return "9:16"
        case .square: return "1:1"
        case .portrait: return "4:5"
        case .widescreen: return "16:9"
        }
    }

    var platformName: String {
        switch self {
        case .vertical: return "TikTok · Reels · Shorts"
        case .square: return "Square Post"
        case .portrait: return "Instagram Feed"
        case .widescreen: return "YouTube"
        }
    }

    /// Render size with the given short side, rounded to even pixel counts.
    func renderSize(shortSide: CGFloat) -> CGSize {
        let r = ratio
        let isLandscape = r.width >= r.height
        let shortRatio = min(r.width, r.height)
        let longRatio = max(r.width, r.height)
        let long = (shortSide * longRatio / shortRatio / 2).rounded() * 2
        return isLandscape ? CGSize(width: long, height: shortSide) : CGSize(width: shortSide, height: long)
    }
}

enum CanvasBackground: String, Codable, CaseIterable, Identifiable {
    case blur, black, white
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct CanvasSettings: Codable, Equatable {
    var aspect: AspectRatio = .vertical
    var background: CanvasBackground = .blur
}

enum MediaKind: String, Codable {
    case video, image, audio
}

/// A file inside the project's media folder.
struct MediaAsset: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: MediaKind
    var fileName: String
    var proxyFileName: String?
    var displayName: String
    var duration: Double
    var width: Double
    var height: Double
    /// Rotation (degrees) needed to display the file upright.
    var orientation: Int = 0
    var proxyOrientation: Int = 0
    var hasAudio: Bool
    var hasVideo: Bool
}

// MARK: - Timeline items

struct VideoClip: Codable, Identifiable, Equatable {
    var id = UUID()
    var mediaID: UUID
    var isImage = false
    var trimStart: Double
    var trimEnd: Double
    var startTime: Double = 0
    var speed = SpeedSettings()
    var volume: Double = 1
    var isMuted = false
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var crop = CropSettings()
    var fit: FitMode = .fit
    var transform = TransformValues()
    var keyframes: [Keyframe] = []
    var effects = ClipEffects()
    var transitionOut = Transition()
    var stabilization: [StabilizationSample]?
    var isReversed = false

    var sourceDuration: Double { max(trimEnd - trimStart, 0) }

    var duration: Double {
        isImage ? sourceDuration : SpeedMath.timelineDuration(sourceDuration: sourceDuration, speed: speed)
    }

    var endTime: Double { startTime + duration }

    func sourceTime(atTimeline time: Double) -> Double {
        let offset = (time - startTime).clamped(0...max(duration, 0))
        if isImage { return trimStart + offset }
        return trimStart + SpeedMath.sourceOffset(timelineOffset: offset, sourceDuration: sourceDuration, speed: speed)
    }
}

enum AudioRole: String, Codable {
    case music, voiceover, extracted

    var title: String {
        switch self {
        case .music: return "Music"
        case .voiceover: return "Voiceover"
        case .extracted: return "Clip Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .music: return "music.note"
        case .voiceover: return "mic.fill"
        case .extracted: return "waveform"
        }
    }
}

struct AudioClip: Codable, Identifiable, Equatable {
    var id = UUID()
    var mediaID: UUID
    var role: AudioRole
    var trimStart: Double
    var trimEnd: Double
    var startTime: Double
    var volume: Double = 1
    var isMuted = false
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    /// Detected beats, in source seconds.
    var beats: [Double] = []

    var duration: Double { max(trimEnd - trimStart, 0) }
    var endTime: Double { startTime + duration }

    /// Beats that fall inside the trimmed range, in timeline seconds.
    var timelineBeats: [Double] {
        beats.filter { $0 >= trimStart && $0 <= trimEnd }.map { startTime + $0 - trimStart }
    }
}

enum TextAnimation: String, Codable, CaseIterable, Identifiable {
    case none, fade, pop, slide, typewriter
    var id: String { rawValue }
    var title: String { rawValue == "none" ? "None" : rawValue.capitalized }
}

enum TextAlign: String, Codable, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
    var systemImage: String { "text.align\(rawValue)" }
}

struct TextStyle: Codable, Equatable {
    var font: FontChoice = .sfRounded
    var isBold = true
    /// Font size as a fraction of the canvas height.
    var size: Double = 0.055
    var color: RGBAColor = .white
    var outlineEnabled = false
    var outlineColor: RGBAColor = .black
    var shadowEnabled = true
    var backgroundEnabled = false
    var backgroundColor = RGBAColor(0, 0, 0, 0.6)
    var alignment: TextAlign = .center
}

struct TextItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var startTime: Double
    var duration: Double = 3
    var style = TextStyle()
    var inAnimation: TextAnimation = .pop
    var outAnimation: TextAnimation = .fade
    var transform = TransformValues()
    var keyframes: [Keyframe] = []

    var endTime: Double { startTime + duration }
}

enum OverlayShape: String, Codable, CaseIterable, Identifiable {
    case rectangle, roundedRectangle, circle, star, heart, arrow
    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .roundedRectangle: return "Rounded"
        case .circle: return "Circle"
        case .star: return "Star"
        case .heart: return "Heart"
        case .arrow: return "Arrow"
        }
    }

    var systemImage: String {
        switch self {
        case .rectangle: return "rectangle.fill"
        case .roundedRectangle: return "app.fill"
        case .circle: return "circle.fill"
        case .star: return "star.fill"
        case .heart: return "heart.fill"
        case .arrow: return "arrow.right"
        }
    }
}

enum OverlayContent: Codable, Equatable {
    case image(UUID)
    case sticker(String)
    case shape(OverlayShape)
}

struct OverlayItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var content: OverlayContent
    var color: RGBAColor = .yellow
    var startTime: Double
    var duration: Double = 3
    /// Width as a fraction of the canvas width.
    var size: Double = 0.4
    var transform = TransformValues()
    var keyframes: [Keyframe] = []

    var endTime: Double { startTime + duration }

    var title: String {
        switch content {
        case .image: return "Image"
        case .sticker(let emoji): return emoji
        case .shape(let shape): return shape.title
        }
    }
}

struct CaptionWord: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var start: Double
    var end: Double
}

struct CaptionLine: Codable, Identifiable, Equatable {
    var id = UUID()
    var words: [CaptionWord]

    var start: Double { words.first?.start ?? 0 }
    var end: Double { words.last?.end ?? 0 }
    var text: String { words.map(\.text).joined(separator: " ") }

    /// Replaces the text, spreading the new words evenly over the same time span.
    mutating func setText(_ newText: String) {
        let tokens = newText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let lineStart = start
        let lineEnd = max(end, start + 0.2)
        guard !tokens.isEmpty else {
            words = []
            return
        }
        let step = (lineEnd - lineStart) / Double(tokens.count)
        words = tokens.enumerated().map { index, token in
            CaptionWord(text: token, start: lineStart + Double(index) * step, end: lineStart + Double(index + 1) * step)
        }
    }
}

enum CaptionStyle: String, Codable, CaseIterable, Identifiable {
    case boldCenter, karaoke, minimalBottom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .boldCenter: return "Bold Center"
        case .karaoke: return "Karaoke"
        case .minimalBottom: return "Minimal"
        }
    }
}

struct CaptionTrack: Codable, Equatable {
    var lines: [CaptionLine] = []
    var style: CaptionStyle = .boldCenter
    var font: FontChoice = .sfRounded
}

// MARK: - Project

enum Selection: Codable, Hashable {
    case video(UUID)
    case audio(UUID)
    case text(UUID)
    case overlay(UUID)
    case caption(UUID)

    var id: UUID {
        switch self {
        case .video(let id), .audio(let id), .text(let id), .overlay(let id), .caption(let id): return id
        }
    }
}

/// Editor state restored when a project is reopened.
struct EditorState: Codable, Equatable {
    var playhead: Double = 0
    var pixelsPerSecond: Double = 64
    var selection: Selection?
}

struct Project: Codable, Identifiable {
    static let currentVersion = 1

    var id = UUID()
    var name: String
    var createdAt = Date()
    var updatedAt = Date()
    var canvas = CanvasSettings()
    var media: [MediaAsset] = []
    var videoClips: [VideoClip] = []
    var audioClips: [AudioClip] = []
    var texts: [TextItem] = []
    var overlays: [OverlayItem] = []
    var captions = CaptionTrack()
    var globalEffects = ClipEffects()
    var isMagnetic = true
    var editor = EditorState()
    var version = Project.currentVersion

    var duration: Double {
        var end = videoClips.map(\.endTime).max() ?? 0
        end = max(end, audioClips.map(\.endTime).max() ?? 0)
        end = max(end, texts.map(\.endTime).max() ?? 0)
        end = max(end, overlays.map(\.endTime).max() ?? 0)
        end = max(end, captions.lines.map(\.end).max() ?? 0)
        return end
    }

    func media(_ id: UUID) -> MediaAsset? {
        media.first { $0.id == id }
    }

    /// The undoable content (everything except editor state).
    var content: ProjectContent {
        ProjectContent(canvas: canvas, media: media, videoClips: videoClips, audioClips: audioClips,
                       texts: texts, overlays: overlays, captions: captions,
                       globalEffects: globalEffects, isMagnetic: isMagnetic)
    }

    mutating func apply(_ content: ProjectContent) {
        canvas = content.canvas
        media = content.media
        videoClips = content.videoClips
        audioClips = content.audioClips
        texts = content.texts
        overlays = content.overlays
        captions = content.captions
        globalEffects = content.globalEffects
        isMagnetic = content.isMagnetic
    }

    /// Lays out the main track: back-to-back when magnetic, otherwise only
    /// pushes clips right to remove overlaps.
    mutating func layoutMainTrack() {
        var cursor = 0.0
        for index in videoClips.indices {
            if isMagnetic {
                videoClips[index].startTime = cursor
            } else {
                videoClips[index].startTime = max(videoClips[index].startTime, cursor)
            }
            cursor = videoClips[index].endTime
        }
        if isMagnetic {
            packLane(&audioClips, start: \.startTime, end: \.endTime)
        }
    }

    private func packLane<Item>(_ items: inout [Item], start: WritableKeyPath<Item, Double>, end: KeyPath<Item, Double>) {
        // Audio is packed only to remove overlaps between consecutive items
        // that started in order; free gaps are respected for music beds.
        let order = items.indices.sorted { items[$0][keyPath: start] < items[$1][keyPath: start] }
        var cursor = -Double.infinity
        for index in order {
            if items[index][keyPath: start] < cursor {
                items[index][keyPath: start] = cursor
            }
            cursor = items[index][keyPath: end]
        }
    }
}

/// Snapshot used for undo and redo.
struct ProjectContent: Equatable {
    var canvas: CanvasSettings
    var media: [MediaAsset]
    var videoClips: [VideoClip]
    var audioClips: [AudioClip]
    var texts: [TextItem]
    var overlays: [OverlayItem]
    var captions: CaptionTrack
    var globalEffects: ClipEffects
    var isMagnetic: Bool
}

/// Listing info for the home screen.
struct ProjectSummary: Identifiable, Hashable {
    let id: UUID
    var name: String
    var updatedAt: Date
    var aspect: AspectRatio
    var duration: Double
}
