import AVFoundation
import Photos
import UIKit

enum ExportResolution: String, CaseIterable, Identifiable, Codable {
    case p720, p1080, p2160
    var id: String { rawValue }

    var shortSide: CGFloat {
        switch self {
        case .p720: return 720
        case .p1080: return 1080
        case .p2160: return 2160
        }
    }

    var title: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p2160: return "4K"
        }
    }
}

enum ExportCodec: String, CaseIterable, Identifiable, Codable {
    case h264, hevc
    var id: String { rawValue }
    var title: String { self == .h264 ? "H.264" : "HEVC" }
    var codecType: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

struct ExportSettings: Equatable {
    var resolution: ExportResolution = .p1080
    var frameRate: Int = 30
    var codec: ExportCodec = .h264
    /// 0...1, mapped to bits per pixel.
    var quality: Double = 0.6

    func renderSize(for aspect: AspectRatio) -> CGSize {
        aspect.renderSize(shortSide: resolution.shortSide)
    }

    func videoBitrate(for aspect: AspectRatio) -> Int {
        let size = renderSize(for: aspect)
        let bitsPerPixel = (0.04 + quality * 0.16) * (codec == .hevc ? 0.6 : 1)
        return Int(Double(size.width * size.height) * Double(frameRate) * bitsPerPixel)
    }

    static let audioBitrate = 160_000

    func estimatedBytes(duration: Double, aspect: AspectRatio) -> Int64 {
        Int64(Double(videoBitrate(for: aspect) + ExportSettings.audioBitrate) * duration / 8)
    }
}

enum ExportError: LocalizedError {
    case cancelled
    case nothingToExport
    case lowStorage
    case photosDenied
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Export cancelled."
        case .nothingToExport: return "Add a clip before exporting."
        case .lowStorage: return "There isn't enough free storage for this export. Try a lower resolution or free up space."
        case .photosDenied: return "Cutline can't save to Photos. Allow access in Settings > Privacy > Photos."
        case .failed(let reason): return "Export failed: \(reason)"
        }
    }
}

/// Renders the full-quality timeline (original media, not proxies) with
/// AVAssetReader/AVAssetWriter so resolution, frame rate, codec and bitrate
/// are all under our control.
final class ExportService: @unchecked Sendable {
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        // Cancelling the reader ends both writing loops; the writer is
        // cancelled once they have drained.
        reader?.cancelReading()
        lock.unlock()
    }

    func exportVideo(project: Project, settings: ExportSettings,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard project.duration > 0.05 else { throw ExportError.nothingToExport }
        let estimate = settings.estimatedBytes(duration: project.duration, aspect: project.canvas.aspect)
        do {
            try ProjectStore.shared.ensureSpace(bytes: Int64(Double(estimate) * 1.2))
        } catch {
            throw ExportError.lowStorage
        }
        let renderSize = settings.renderSize(for: project.canvas.aspect)
        let build = try await CompositionBuilder.build(project: project, renderSize: renderSize,
                                                       frameRate: settings.frameRate, useProxies: false)
        let url = ExportService.outputURL(name: project.name, ext: "mp4")

        let reader = try AVAssetReader(asset: build.composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: CompositionBuilder.time(build.duration))
        let videoTracks = try await build.composition.loadTracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.videoComposition = build.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ExportError.failed("video output") }
        reader.add(videoOutput)

        let audioTracks = try await build.composition.loadTracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2
            ])
            output.audioMix = build.audioMix
            output.audioTimePitchAlgorithm = .spectral
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec.codecType,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.videoBitrate(for: project.canvas.aspect),
                AVVideoExpectedSourceFrameRateKey: settings.frameRate,
                AVVideoMaxKeyFrameIntervalKey: settings.frameRate * 2
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ExportError.failed("video encoder") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: ExportSettings.audioBitrate
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        lock.lock()
        self.reader = reader
        self.writer = writer
        let cancelledEarly = isCancelled
        lock.unlock()
        if cancelledEarly { throw ExportError.cancelled }

        guard writer.startWriting() else { throw ExportError.failed(writer.error?.localizedDescription ?? "writer") }
        guard reader.startReading() else { throw ExportError.failed(reader.error?.localizedDescription ?? "reader") }
        writer.startSession(atSourceTime: .zero)

        let duration = build.duration
        let group = DispatchGroup()
        group.enter()
        let videoQueue = DispatchQueue(label: "com.cutline.export.video")
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                guard let sample = videoOutput.copyNextSampleBuffer() else {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if !videoInput.append(sample) {
                    reader.cancelReading()
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                progress(min(0.99, seconds / max(duration, 0.01)))
            }
        }
        if let audioInput, let audioOutput {
            group.enter()
            let audioQueue = DispatchQueue(label: "com.cutline.export.audio")
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    guard let sample = audioOutput.copyNextSampleBuffer(), audioInput.append(sample) else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) {
                continuation.resume()
            }
        }

        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw ExportError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw ExportError.failed(reader.error?.localizedDescription ?? "reading media")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.failed(writer.error?.localizedDescription ?? "writing file")
        }
        progress(1)
        return url
    }

    // MARK: Audio only and stills

    static func exportAudio(project: Project) async throws -> URL {
        guard project.duration > 0.05 else { throw ExportError.nothingToExport }
        let build = try await CompositionBuilder.build(project: project, renderSize: CGSize(width: 64, height: 64),
                                                       frameRate: 30, useProxies: true)
        guard !build.composition.tracks(withMediaType: .audio).isEmpty else {
            throw ExportError.failed("this project has no audio")
        }
        guard let session = AVAssetExportSession(asset: build.composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.failed("audio export isn't available")
        }
        let url = outputURL(name: project.name, ext: "m4a")
        session.outputURL = url
        session.outputFileType = .m4a
        session.audioMix = build.audioMix
        session.audioTimePitchAlgorithm = .spectral
        session.timeRange = CMTimeRange(start: .zero, duration: CompositionBuilder.time(build.duration))
        await session.export()
        guard session.status == .completed else {
            throw ExportError.failed(session.error?.localizedDescription ?? "audio")
        }
        return url
    }

    static func stillFrame(project: Project, at time: Double, shortSide: CGFloat = 1080) async throws -> UIImage {
        let renderSize = project.canvas.aspect.renderSize(shortSide: shortSide)
        let build = try await CompositionBuilder.build(project: project, renderSize: renderSize, frameRate: 30, useProxies: false)
        let generator = AVAssetImageGenerator(asset: build.composition)
        generator.videoComposition = build.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = renderSize
        let clamped = min(max(time, 0), max(build.duration - 0.05, 0))
        let (cgImage, _) = try await generator.image(at: CompositionBuilder.time(clamped))
        return UIImage(cgImage: cgImage)
    }

    // MARK: Photos

    static func saveVideoToPhotos(_ url: URL) async throws {
        try await requestPhotosAccess()
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    static func saveImageToPhotos(_ image: UIImage) async throws {
        try await requestPhotosAccess()
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetCreationRequest.creationRequestForAsset(from: image)
        }
    }

    private static func requestPhotosAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.photosDenied }
    }

    static func outputURL(name: String, ext: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var clean = name.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { clean = "Cutline" }
        let url = directory.appendingPathComponent("\(clean).\(ext)")
        try? FileManager.default.removeItem(at: url)
        return url
    }
}
