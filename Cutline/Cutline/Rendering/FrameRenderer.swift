import AVFoundation
import CoreImage
import Metal
import Vision

/// Immutable description of what to draw, shared with the compositor.
final class RenderPlan: @unchecked Sendable {
    let project: Project
    let renderSize: CGSize
    let trackIDs: [UUID: CMPersistentTrackID]
    let mainClips: [VideoClip]
    let media: [UUID: MediaAsset]
    let proxiedMedia: Set<UUID>
    let mediaDirectory: URL

    init(project: Project, renderSize: CGSize, trackIDs: [UUID: CMPersistentTrackID],
         proxiedMedia: Set<UUID>, mediaDirectory: URL) {
        self.project = project
        self.renderSize = renderSize
        self.trackIDs = trackIDs
        self.mainClips = project.videoClips.sorted { $0.startTime < $1.startTime }
        var table: [UUID: MediaAsset] = [:]
        for asset in project.media {
            table[asset.id] = asset
        }
        self.media = table
        self.proxiedMedia = proxiedMedia
        self.mediaDirectory = mediaDirectory
    }

    func url(for asset: MediaAsset) -> URL {
        if proxiedMedia.contains(asset.id), let proxy = asset.proxyFileName {
            return mediaDirectory.appendingPathComponent(proxy)
        }
        return mediaDirectory.appendingPathComponent(asset.fileName)
    }

    func orientation(for asset: MediaAsset) -> Int {
        proxiedMedia.contains(asset.id) ? asset.proxyOrientation : asset.orientation
    }

    /// Transition length between two adjacent clips, limited so neither clip
    /// is more than half consumed.
    static func transitionDuration(from clip: VideoClip, to next: VideoClip) -> Double {
        guard clip.transitionOut.kind != .cut, abs(next.startTime - clip.endTime) < 0.01 else { return 0 }
        return min(clip.transitionOut.duration, clip.duration / 2, next.duration / 2)
    }
}

/// Draws one output frame: main clips (with crop, keying, background
/// removal, stabilization, filters, fit/fill, keyframes and transitions),
/// global filters, overlays, titles and captions.
final class FrameRenderer: @unchecked Sendable {
    static let shared = FrameRenderer()

    let context: CIContext
    private let stillCache = NSCache<NSString, CIImage>()

    private init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "Cutline"])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
        stillCache.countLimit = 40
    }

    func render(plan: RenderPlan, time: Double, frames: [CMPersistentTrackID: CVPixelBuffer]) -> CIImage {
        let canvas = CGRect(origin: .zero, size: plan.renderSize)
        let black = CIImage(color: .black).cropped(to: canvas)
        var output = black

        let clips = plan.mainClips
        if let index = clips.firstIndex(where: { time >= $0.startTime && time < $0.endTime }) {
            let clip = clips[index]
            var frame = composeClip(clip, time: time, plan: plan, frames: frames, canvas: canvas)
            if index + 1 < clips.count {
                let next = clips[index + 1]
                let duration = RenderPlan.transitionDuration(from: clip, to: next)
                if duration > 0, time >= clip.endTime - duration {
                    let incoming = composeClip(next, time: time, plan: plan, frames: frames, canvas: canvas)
                    let progress = (time - (clip.endTime - duration)) / duration
                    frame = FilterLibrary.transition(clip.transitionOut.kind, from: frame, to: incoming,
                                                     progress: progress, canvas: canvas)
                }
            }
            output = frame
        }

        if !plan.project.globalEffects.isNeutral {
            output = FilterLibrary.apply(plan.project.globalEffects, to: output, time: time).cropped(to: canvas)
        }
        for overlay in plan.project.overlays where time >= overlay.startTime && time < overlay.endTime {
            if let layer = overlayLayer(overlay, time: time, plan: plan, canvas: canvas) {
                output = layer.composited(over: output)
            }
        }
        for text in plan.project.texts where time >= text.startTime && time < text.endTime {
            if let layer = textLayer(text, time: time, canvas: canvas) {
                output = layer.composited(over: output)
            }
        }
        if let layer = captionLayer(plan.project.captions, time: time, canvas: canvas) {
            output = layer.composited(over: output)
        }
        return output.composited(over: black).cropped(to: canvas)
    }

    // MARK: Main clips

    /// A full-canvas, opaque frame for one clip: background plus the placed clip.
    private func composeClip(_ clip: VideoClip, time: Double, plan: RenderPlan,
                             frames: [CMPersistentTrackID: CVPixelBuffer], canvas: CGRect) -> CIImage {
        let black = CIImage(color: .black).cropped(to: canvas)
        guard let source = clipSource(clip, time: time, plan: plan, frames: frames) else { return black }
        let extent = source.extent
        guard extent.width > 1, extent.height > 1 else { return black }

        let background: CIImage
        switch plan.project.canvas.background {
        case .black:
            background = black
        case .white:
            background = CIImage(color: .white).cropped(to: canvas)
        case .blur:
            let fill = max(canvas.width / extent.width, canvas.height / extent.height) * 1.1
            background = place(source, scale: fill, values: .identity, canvas: canvas)
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: canvas.width * 0.05])
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.12, kCIInputSaturationKey: 1.1])
                .cropped(to: canvas)
        }

        let fitScale = clip.fit == .fit
            ? min(canvas.width / extent.width, canvas.height / extent.height)
            : max(canvas.width / extent.width, canvas.height / extent.height)
        let values = KeyframeMath.value(base: clip.transform, keyframes: clip.keyframes, at: time - clip.startTime)
        let placed = place(source, scale: fitScale * CGFloat(values.scale), values: values, canvas: canvas)
        return FilterLibrary.opacity(placed, values.opacity).composited(over: background).cropped(to: canvas)
    }

    /// The clip's frame with orientation, crop, rotation, flips,
    /// stabilization, keying and filters applied, with its origin at zero.
    private func clipSource(_ clip: VideoClip, time: Double, plan: RenderPlan,
                            frames: [CMPersistentTrackID: CVPixelBuffer]) -> CIImage? {
        guard let asset = plan.media[clip.mediaID] else { return nil }
        var image: CIImage
        if clip.isImage {
            guard let still = stillImage(url: plan.url(for: asset)) else { return nil }
            image = still
        } else {
            guard let trackID = plan.trackIDs[clip.id], let buffer = frames[trackID] else { return nil }
            image = CIImage(cvPixelBuffer: buffer)
            if clip.effects.removeBackground {
                image = removeBackground(buffer: buffer, image: image)
            }
            image = FrameRenderer.orient(image, degrees: plan.orientation(for: asset))
        }
        image = FrameRenderer.originAtZero(image)

        let crop = clip.crop
        if !crop.isIdentity {
            let w = image.extent.width
            let h = image.extent.height
            let rect = CGRect(x: w * CGFloat(crop.left),
                              y: h * CGFloat(crop.bottom),
                              width: max(2, w * CGFloat(1 - crop.left - crop.right)),
                              height: max(2, h * CGFloat(1 - crop.top - crop.bottom)))
            image = FrameRenderer.originAtZero(image.cropped(to: rect))
            let turns = ((crop.quarterTurns % 4) + 4) % 4
            if turns > 0 {
                let orientation: CGImagePropertyOrientation = turns == 1 ? .right : (turns == 2 ? .down : .left)
                image = FrameRenderer.originAtZero(image.oriented(orientation))
            }
            if crop.flipHorizontal {
                image = FrameRenderer.originAtZero(image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)))
            }
            if crop.flipVertical {
                image = FrameRenderer.originAtZero(image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)))
            }
        }

        if let samples = clip.stabilization, !samples.isEmpty, !clip.isImage {
            let sample = FrameRenderer.nearest(samples, to: clip.sourceTime(atTimeline: time))
            let extent = image.extent
            let zoom: CGFloat = 1.1
            let moved = image
                .transformed(by: CGAffineTransform(translationX: CGFloat(sample.dx) * extent.width,
                                                   y: -CGFloat(sample.dy) * extent.height))
            image = FilterLibrary.scaled(moved.clampedToExtent(), by: zoom, around: extent.center).cropped(to: extent)
        }

        if clip.effects.chromaKey.isEnabled {
            image = FilterLibrary.chromaKey(image, settings: clip.effects.chromaKey)
        }
        image = FilterLibrary.apply(clip.effects, to: image, time: time)
        return image
    }

    // MARK: Overlays, titles, captions

    private func overlayLayer(_ overlay: OverlayItem, time: Double, plan: RenderPlan, canvas: CGRect) -> CIImage? {
        let targetWidth = CGFloat(overlay.size) * canvas.width
        let values = KeyframeMath.value(base: overlay.transform, keyframes: overlay.keyframes, at: time - overlay.startTime)
        let image: CIImage?
        var baseScale: CGFloat = 1
        switch overlay.content {
        case .image(let mediaID):
            guard let asset = plan.media[mediaID], let still = stillImage(url: plan.url(for: asset)) else { return nil }
            image = still
            baseScale = targetWidth / max(still.extent.width, 1)
        case .sticker(let emoji):
            image = TextRenderer.shared.stickerImage(emoji, pixelWidth: targetWidth)
        case .shape(let shape):
            image = TextRenderer.shared.shapeImage(shape, color: overlay.color, pixelWidth: targetWidth)
        }
        guard let image else { return nil }
        let placed = place(image, scale: baseScale * CGFloat(values.scale), values: values, canvas: canvas)
        return FilterLibrary.opacity(placed, values.opacity)
    }

    private func textLayer(_ item: TextItem, time: Double, canvas: CGRect) -> CIImage? {
        let local = time - item.startTime
        let animationLength = min(0.4, item.duration / 3)
        var alpha = 1.0
        var scale = 1.0
        var offsetY = 0.0
        var characters: Int?

        if item.inAnimation == .typewriter {
            let typingTime = max(item.duration * 0.5, 0.1)
            characters = Int((Double(item.text.count) * min(1, local / typingTime)).rounded(.up))
        }
        if local < animationLength {
            let p = local / animationLength
            switch item.inAnimation {
            case .none, .typewriter: break
            case .fade: alpha = p
            case .pop: scale = max(0.01, Easing.bounce.apply(p))
            case .slide:
                offsetY = (1 - Easing.easeOut.apply(p)) * 0.08
                alpha = p
            }
        }
        let remaining = item.duration - local
        if remaining < animationLength {
            let p = remaining / animationLength
            switch item.outAnimation {
            case .none: break
            case .fade, .typewriter: alpha *= p
            case .pop: scale *= max(0.01, Easing.easeIn.apply(p))
            case .slide:
                offsetY -= (1 - Easing.easeIn.apply(p)) * 0.08
                alpha *= p
            }
        }

        guard let image = TextRenderer.shared.image(for: item, canvas: canvas.size, visibleCharacters: characters) else { return nil }
        var values = KeyframeMath.value(base: item.transform, keyframes: item.keyframes, at: local)
        values.y += offsetY
        let placed = place(image, scale: CGFloat(values.scale * scale), values: values, canvas: canvas)
        return FilterLibrary.opacity(placed, values.opacity * alpha)
    }

    private func captionLayer(_ track: CaptionTrack, time: Double, canvas: CGRect) -> CIImage? {
        guard let line = track.lines.first(where: { time >= $0.start && time < $0.end }) else { return nil }
        let highlighted = line.words.lastIndex { $0.start <= time }
        guard let image = TextRenderer.shared.captionImage(line: line, track: track, highlightedWord: highlighted,
                                                           canvas: canvas.size) else { return nil }
        var values = TransformValues()
        values.y = TextRenderer.captionCenterY(track.style) - 0.5
        return place(image, scale: 1, values: values, canvas: canvas)
    }

    // MARK: Helpers

    /// Centers the image on the canvas, then applies scale, rotation and offset.
    private func place(_ image: CIImage, scale: CGFloat, values: TransformValues, canvas: CGRect) -> CIImage {
        let extent = image.extent
        let radians = -CGFloat(values.rotation) * .pi / 180
        let transform = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: radians))
            .concatenating(CGAffineTransform(translationX: canvas.midX + CGFloat(values.x) * canvas.width,
                                             y: canvas.midY - CGFloat(values.y) * canvas.height))
        return image.transformed(by: transform)
    }

    private func stillImage(url: URL) -> CIImage? {
        let key = url.path as NSString
        if let cached = stillCache.object(forKey: key) {
            return cached
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let normalized = FrameRenderer.originAtZero(image)
        stillCache.setObject(normalized, forKey: key)
        return normalized
    }

    private func removeBackground(buffer: CVPixelBuffer, image: CIImage) -> CIImage {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return image
        }
        guard let maskBuffer = request.results?.first?.pixelBuffer else { return image }
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        let scaleX = image.extent.width / max(mask.extent.width, 1)
        let scaleY = image.extent.height / max(mask.extent.height, 1)
        mask = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ])
    }

    static func orient(_ image: CIImage, degrees: Int) -> CIImage {
        switch degrees {
        case 90: return image.oriented(.right)
        case 180: return image.oriented(.down)
        case 270: return image.oriented(.left)
        default: return image
        }
    }

    static func originAtZero(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.minX != 0 || extent.minY != 0 else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }

    static func nearest(_ samples: [StabilizationSample], to time: Double) -> StabilizationSample {
        var low = 0
        var high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low > 0, abs(samples[low - 1].time - time) < abs(samples[low].time - time) {
            return samples[low - 1]
        }
        return samples[low]
    }
}
