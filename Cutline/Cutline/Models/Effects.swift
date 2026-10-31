import Foundation

/// Manual color and detail adjustments. Neutral values leave the image unchanged.
struct Adjustments: Codable, Equatable {
    var brightness: Double = 0      // -0.5...0.5
    var contrast: Double = 1        // 0.5...1.5
    var saturation: Double = 1      // 0...2
    var warmth: Double = 0          // -1...1
    var tint: Double = 0            // -1...1
    var sharpen: Double = 0         // 0...1
    var vignette: Double = 0        // 0...1
    var grain: Double = 0           // 0...1
    var blur: Double = 0            // 0...1

    var isNeutral: Bool { self == Adjustments() }
}

enum FilterPreset: String, Codable, CaseIterable, Identifiable {
    case none, vivid, punch, warm, cool, cinematic, vintage, dreamy, fade, chrome, instant, process, transfer, tonal, mono, noir

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Original"
        case .vivid: return "Vivid"
        case .punch: return "Punch"
        case .warm: return "Warm"
        case .cool: return "Cool"
        case .cinematic: return "Cinematic"
        case .vintage: return "Vintage"
        case .dreamy: return "Dreamy"
        case .fade: return "Fade"
        case .chrome: return "Chrome"
        case .instant: return "Instant"
        case .process: return "Process"
        case .transfer: return "Transfer"
        case .tonal: return "Tonal"
        case .mono: return "Mono"
        case .noir: return "Noir"
        }
    }
}

struct ChromaKey: Codable, Equatable {
    var isEnabled = false
    var color: RGBAColor = .green
    var tolerance: Double = 0.18   // hue distance, 0.02...0.5
    var softness: Double = 0.08    // edge falloff, 0...0.3
}

/// Everything that can be copied and pasted between clips.
struct ClipEffects: Codable, Equatable {
    var preset: FilterPreset = .none
    var presetIntensity: Double = 1
    var adjustments = Adjustments()
    var chromaKey = ChromaKey()
    var removeBackground = false

    var isNeutral: Bool { self == ClipEffects() }
}

/// Crop insets (fractions of the oriented source), rotation and flips.
struct CropSettings: Codable, Equatable {
    var left: Double = 0
    var top: Double = 0
    var right: Double = 0
    var bottom: Double = 0
    var quarterTurns: Int = 0
    var flipHorizontal = false
    var flipVertical = false

    var isIdentity: Bool { self == CropSettings() }
}

enum FitMode: String, Codable, CaseIterable, Identifiable {
    case fit, fill
    var id: String { rawValue }
    var title: String { self == .fit ? "Fit" : "Fill" }
}

enum TransitionKind: String, Codable, CaseIterable, Identifiable {
    case cut, fade, dissolve, slide, zoom, spin, glitch

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .cut: return "scissors"
        case .fade: return "circle.lefthalf.filled"
        case .dissolve: return "square.on.square.dashed"
        case .slide: return "rectangle.righthalf.inset.filled.arrow.right"
        case .zoom: return "plus.magnifyingglass"
        case .spin: return "arrow.triangle.2.circlepath"
        case .glitch: return "waveform.path.ecg"
        }
    }
}

struct Transition: Codable, Equatable {
    var kind: TransitionKind = .cut
    var duration: Double = 0.5
}

enum SpeedRamp: String, Codable, CaseIterable, Identifiable {
    case none, montage, hero, bullet, flashIn, flashOut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .montage: return "Montage"
        case .hero: return "Hero"
        case .bullet: return "Bullet"
        case .flashIn: return "Flash In"
        case .flashOut: return "Flash Out"
        }
    }

    /// Speed multiplier control points (position in clip 0...1, multiplier).
    var points: [(Double, Double)] {
        switch self {
        case .none: return [(0, 1), (1, 1)]
        case .montage: return [(0, 1), (0.25, 0.4), (0.5, 2.5), (0.75, 0.4), (1, 1)]
        case .hero: return [(0, 1.6), (0.4, 1.6), (0.5, 0.3), (0.6, 1.6), (1, 1.6)]
        case .bullet: return [(0, 2), (0.35, 2), (0.5, 0.2), (0.65, 2), (1, 2)]
        case .flashIn: return [(0, 4), (0.4, 1), (1, 1)]
        case .flashOut: return [(0, 1), (0.6, 1), (1, 4)]
        }
    }

    func multiplier(at position: Double) -> Double {
        let pts = points
        guard let first = pts.first, let last = pts.last else { return 1 }
        if position <= first.0 { return first.1 }
        if position >= last.0 { return last.1 }
        for index in 0..<(pts.count - 1) where position >= pts[index].0 && position <= pts[index + 1].0 {
            let span = max(pts[index + 1].0 - pts[index].0, 0.000_1)
            let t = Easing.easeInOut.apply((position - pts[index].0) / span)
            return pts[index].1 + (pts[index + 1].1 - pts[index].1) * t
        }
        return last.1
    }
}

struct SpeedSettings: Codable, Equatable {
    var rate: Double = 1
    var ramp: SpeedRamp = .none

    var isNormal: Bool { rate == 1 && ramp == .none }
}

/// Maps source time to timeline time for clips with constant speed or ramps.
/// Ramps are approximated with short constant-speed segments, which play
/// smoothly because each segment is scaled individually in the composition.
enum SpeedMath {
    static let rampSegments = 24
    static let minSpeed = 0.1
    static let maxSpeed = 8.0

    struct Segment {
        let sourceStart: Double
        let sourceDuration: Double
        let timelineDuration: Double
    }

    static func segments(sourceDuration: Double, speed: SpeedSettings) -> [Segment] {
        guard sourceDuration > 0 else { return [] }
        if speed.ramp == .none {
            let rate = speed.rate.clamped(minSpeed...maxSpeed)
            return [Segment(sourceStart: 0, sourceDuration: sourceDuration, timelineDuration: sourceDuration / rate)]
        }
        let count = rampSegments
        let step = sourceDuration / Double(count)
        return (0..<count).map { index in
            let position = (Double(index) + 0.5) / Double(count)
            let rate = (speed.rate * speed.ramp.multiplier(at: position)).clamped(minSpeed...maxSpeed)
            return Segment(sourceStart: Double(index) * step, sourceDuration: step, timelineDuration: step / rate)
        }
    }

    static func timelineDuration(sourceDuration: Double, speed: SpeedSettings) -> Double {
        segments(sourceDuration: sourceDuration, speed: speed).reduce(0) { $0 + $1.timelineDuration }
    }

    /// Source offset (from trim start) shown at a timeline offset (from clip start).
    static func sourceOffset(timelineOffset: Double, sourceDuration: Double, speed: SpeedSettings) -> Double {
        var elapsed = 0.0
        for segment in segments(sourceDuration: sourceDuration, speed: speed) {
            if timelineOffset <= elapsed + segment.timelineDuration {
                let fraction = (timelineOffset - elapsed) / max(segment.timelineDuration, 0.000_1)
                return segment.sourceStart + segment.sourceDuration * fraction.clamped(0...1)
            }
            elapsed += segment.timelineDuration
        }
        return sourceDuration
    }
}

/// Correction offsets produced by stabilization analysis (fractions of the frame).
struct StabilizationSample: Codable, Equatable {
    var time: Double
    var dx: Double
    var dy: Double
}
