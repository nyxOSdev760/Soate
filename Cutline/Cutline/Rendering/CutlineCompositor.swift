import AVFoundation
import CoreImage

/// One instruction covers the whole timeline and carries the render plan.
final class CutlineInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let plan: RenderPlan

    init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], plan: RenderPlan) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
        self.plan = plan
        super.init()
    }
}

enum CompositorError: LocalizedError {
    case badInstruction
    case noBuffer

    var errorDescription: String? {
        switch self {
        case .badInstruction: return "The video couldn't be rendered."
        case .noBuffer: return "There isn't enough memory to render this frame."
        }
    }
}

/// Custom video compositor. AVFoundation decodes the source frames; this
/// class draws effects, keyframes, transitions, text and overlays with a
/// Metal-backed Core Image context on its own queue.
final class CutlineCompositor: NSObject, AVVideoCompositing {
    private let queue = DispatchQueue(label: "com.cutline.compositor", qos: .userInteractive)
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private var shouldCancel = false

    private static let pixelAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
    ]

    var sourcePixelBufferAttributes: [String: Any]? {
        CutlineCompositor.pixelAttributes
    }

    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        CutlineCompositor.pixelAttributes
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            if shouldCancel {
                request.finishCancelledRequest()
                return
            }
            guard let instruction = request.videoCompositionInstruction as? CutlineInstruction else {
                request.finish(with: CompositorError.badInstruction)
                return
            }
            guard let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: CompositorError.noBuffer)
                return
            }
            var frames: [CMPersistentTrackID: CVPixelBuffer] = [:]
            for number in request.sourceTrackIDs {
                let trackID = number.int32Value
                if let buffer = request.sourceFrame(byTrackID: trackID) {
                    frames[trackID] = buffer
                }
            }
            let renderer = FrameRenderer.shared
            var image = renderer.render(plan: instruction.plan, time: request.compositionTime.seconds, frames: frames)
            let target = request.renderContext.size
            let planSize = instruction.plan.renderSize
            if target != planSize, planSize.width > 0, planSize.height > 0 {
                image = image.transformed(by: CGAffineTransform(scaleX: target.width / planSize.width,
                                                                y: target.height / planSize.height))
            }
            renderer.context.render(image, to: output, bounds: CGRect(origin: .zero, size: target), colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: output)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        shouldCancel = true
        queue.async { [self] in
            shouldCancel = false
        }
    }
}
