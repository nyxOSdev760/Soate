import AVFoundation
import CoreImage

struct BuildResult {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix
    let plan: RenderPlan
    let duration: Double
    let missingMedia: [String]
}

/// Builds the AVFoundation composition for a project.
///
/// Main clips alternate between two video tracks (A/B) so a transition can
/// overlap the end of one clip with a pre-roll of the next. Speed changes
/// and ramps are applied by scaling each source segment. A blank base track
/// keeps the compositor running over gaps, still images and titles.
enum CompositionBuilder {
    static let timescale: CMTimeScale = 600

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(seconds, 0), preferredTimescale: timescale)
    }

    static func build(project: Project, renderSize: CGSize, frameRate: Int, useProxies: Bool) async throws -> BuildResult {
        let store = ProjectStore.shared
        let mediaDirectory = store.mediaDirectory(for: project.id)
        let fileManager = FileManager.default

        var proxied = Set<UUID>()
        var missing: [String] = []
        var available = Set<UUID>()
        for asset in project.media {
            let original = mediaDirectory.appendingPathComponent(asset.fileName)
            if useProxies, let proxy = asset.proxyFileName,
               fileManager.fileExists(atPath: mediaDirectory.appendingPathComponent(proxy).path) {
                proxied.insert(asset.id)
                available.insert(asset.id)
            } else if fileManager.fileExists(atPath: original.path) {
                available.insert(asset.id)
            } else {
                missing.append(asset.displayName)
            }
        }

        let composition = AVMutableComposition()
        guard let videoA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let videoB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioB = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CompositorError.badInstruction
        }

        var assets: [UUID: AVURLAsset] = [:]
        func avAsset(_ media: MediaAsset) -> AVURLAsset {
            if let existing = assets[media.id] { return existing }
            let url: URL
            if proxied.contains(media.id), let proxy = media.proxyFileName {
                url = mediaDirectory.appendingPathComponent(proxy)
            } else {
                url = mediaDirectory.appendingPathComponent(media.fileName)
            }
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            assets[media.id] = asset
            return asset
        }

        var trackIDs: [UUID: CMPersistentTrackID] = [:]
        var mainAudioParams: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        let clips = project.videoClips.sorted { $0.startTime < $1.startTime }

        for (index, clip) in clips.enumerated() {
            guard !clip.isImage, let media = project.media(clip.mediaID), media.kind == .video,
                  available.contains(media.id) else { continue }
            let asset = avAsset(media)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
            let videoTrack = index % 2 == 0 ? videoA : videoB
            let audioTrack = index % 2 == 0 ? audioA : audioB
            trackIDs[clip.id] = videoTrack.trackID
            let assetDuration = try await asset.load(.duration).seconds

            // Pre-roll for an incoming transition from the previous clip.
            if index > 0 {
                let previous = clips[index - 1]
                let transitionLength = RenderPlan.transitionDuration(from: previous, to: clip)
                if transitionLength > 0 {
                    let rollStart = clip.startTime - transitionLength
                    let firstRate = SpeedMath.segments(sourceDuration: clip.sourceDuration, speed: clip.speed).first
                        .map { $0.sourceDuration / max($0.timelineDuration, 0.000_1) } ?? 1
                    let handle = transitionLength * firstRate
                    let sourceRange: CMTimeRange
                    if clip.trimStart >= handle {
                        sourceRange = CMTimeRange(start: time(clip.trimStart - handle), duration: time(handle))
                    } else {
                        sourceRange = CMTimeRange(start: time(clip.trimStart), duration: CMTime(value: 1, timescale: 30))
                    }
                    try insert(sourceRange, of: sourceVideo, into: videoTrack, at: rollStart, scaledTo: transitionLength)
                }
            }

            var cursor = clip.startTime
            for segment in SpeedMath.segments(sourceDuration: clip.sourceDuration, speed: clip.speed) {
                let start = clip.trimStart + segment.sourceStart
                let usable = min(segment.sourceDuration, max(0, assetDuration - start))
                guard usable > 0.001 else { continue }
                let range = CMTimeRange(start: time(start), duration: time(usable))
                try insert(range, of: sourceVideo, into: videoTrack, at: cursor, scaledTo: segment.timelineDuration)
                if let sourceAudio, !clip.isMuted, clip.volume > 0 {
                    try insert(range, of: sourceAudio, into: audioTrack, at: cursor, scaledTo: segment.timelineDuration)
                }
                cursor += segment.timelineDuration
            }

            if sourceAudio != nil, !clip.isMuted, clip.volume > 0 {
                let params = mainAudioParams[audioTrack.trackID] ?? AVMutableAudioMixInputParameters(track: audioTrack)
                applyVolume(params, start: clip.startTime, duration: clip.duration, volume: clip.volume,
                            fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
                mainAudioParams[audioTrack.trackID] = params
            }
        }

        // Music, voiceover and detached audio, one composition track per lane.
        var lanes: [(track: AVMutableCompositionTrack, end: Double, params: AVMutableAudioMixInputParameters)] = []
        for clip in project.audioClips.sorted(by: { $0.startTime < $1.startTime }) where !clip.isMuted {
            guard let media = project.media(clip.mediaID), available.contains(media.id) else { continue }
            let asset = avAsset(media)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let laneIndex: Int
            if let existing = lanes.firstIndex(where: { $0.end <= clip.startTime + 0.001 }) {
                laneIndex = existing
            } else {
                guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                lanes.append((track, 0, AVMutableAudioMixInputParameters(track: track)))
                laneIndex = lanes.count - 1
            }
            let range = CMTimeRange(start: time(clip.trimStart), duration: time(clip.duration))
            try insert(range, of: source, into: lanes[laneIndex].track, at: clip.startTime, scaledTo: nil)
            applyVolume(lanes[laneIndex].params, start: clip.startTime, duration: clip.duration,
                        volume: clip.volume, fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
            lanes[laneIndex].end = clip.endTime
        }

        // Base track spanning the whole timeline.
        let total = max(project.duration, 0.5)
        let blankURL = try await BlankVideo.shared.url()
        let blankAsset = AVURLAsset(url: blankURL)
        if let blankTrack = try await blankAsset.loadTracks(withMediaType: .video).first,
           let base = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let blankDuration = try await blankAsset.load(.duration)
            try base.insertTimeRange(CMTimeRange(start: .zero, duration: blankDuration), of: blankTrack, at: .zero)
            base.scaleTimeRange(CMTimeRange(start: .zero, duration: blankDuration), toDuration: time(total))
        }

        for track in composition.tracks where track.segments.isEmpty {
            composition.removeTrack(track)
        }

        let plan = RenderPlan(project: project, renderSize: renderSize, trackIDs: trackIDs,
                              proxiedMedia: proxied, mediaDirectory: mediaDirectory)
        let videoTrackIDs = composition.tracks(withMediaType: .video).map(\.trackID)
        let instruction = CutlineInstruction(timeRange: CMTimeRange(start: .zero, duration: time(total)),
                                             trackIDs: videoTrackIDs, plan: plan)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = CutlineCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(frameRate, 1)))
        videoComposition.instructions = [instruction]

        let audioMix = AVMutableAudioMix()
        let liveAudioIDs = Set(composition.tracks(withMediaType: .audio).map(\.trackID))
        audioMix.inputParameters = (Array(mainAudioParams.values) + lanes.map(\.params))
            .filter { liveAudioIDs.contains($0.trackID) }

        return BuildResult(composition: composition, videoComposition: videoComposition, audioMix: audioMix,
                           plan: plan, duration: total, missingMedia: missing)
    }

    /// Inserts a source range at a timeline position (filling any gap first)
    /// and optionally scales it to a new duration.
    private static func insert(_ range: CMTimeRange, of source: AVAssetTrack, into track: AVMutableCompositionTrack,
                               at start: Double, scaledTo duration: Double?) throws {
        let trackEnd = track.timeRange.end
        var position = time(start)
        if position > trackEnd {
            track.insertEmptyTimeRange(CMTimeRange(start: trackEnd, end: position))
        } else if position < trackEnd {
            position = trackEnd
        }
        try track.insertTimeRange(range, of: source, at: position)
        if let duration, abs(duration - range.duration.seconds) > 0.001 {
            track.scaleTimeRange(CMTimeRange(start: position, duration: range.duration), toDuration: time(duration))
        }
    }

    private static func applyVolume(_ params: AVMutableAudioMixInputParameters, start: Double, duration: Double,
                                    volume: Double, fadeIn: Double, fadeOut: Double) {
        let level = Float(volume)
        let fadeInLength = min(fadeIn, duration / 2)
        let fadeOutLength = min(fadeOut, duration / 2)
        if fadeInLength > 0.01 {
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: level,
                                 timeRange: CMTimeRange(start: time(start), duration: time(fadeInLength)))
        } else {
            params.setVolume(level, at: time(start))
        }
        if fadeOutLength > 0.01 {
            params.setVolumeRamp(fromStartVolume: level, toEndVolume: 0,
                                 timeRange: CMTimeRange(start: time(start + duration - fadeOutLength), duration: time(fadeOutLength)))
        }
    }

    /// Preview renders at 720p on the short side; export uses the chosen size.
    static func previewRenderSize(for aspect: AspectRatio) -> CGSize {
        aspect.renderSize(shortSide: 720)
    }
}

/// A one-second black video used as the composition's base track.
actor BlankVideo {
    static let shared = BlankVideo()

    private var cached: URL?

    func url() async throws -> URL {
        if let cached, FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let url = caches.appendingPathComponent("cutline-blank-v1.mov")
        if FileManager.default.fileExists(atPath: url.path) {
            cached = url
            return url
        }
        try await BlankVideo.write(to: url)
        cached = url
        return url
    }

    private static func write(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let size = 64
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CompositorError.noBuffer }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let pixelBuffer = buffer else { throw CompositorError.noBuffer }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? CompositorError.noBuffer
        }
    }
}
