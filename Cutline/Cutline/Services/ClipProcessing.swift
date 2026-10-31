import AVFoundation
import CoreImage
import Vision

enum ProcessingError: LocalizedError {
    case noVideo
    case noAudio
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: return "This clip has no video to process."
        case .noAudio: return "This clip has no audio."
        case .failed(let reason): return reason
        }
    }
}

/// Writes a reversed copy of a clip's trimmed range (video only), reading
/// the source in short chunks from the end so memory stays bounded.
enum ReverseService {
    static func reverse(source: URL, start: Double, end: Double, output: URL,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProcessingError.noVideo }
        let (naturalSize, transform, nominalRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let fps = nominalRate > 1 ? Double(nominalRate) : 30
        let frameValue = CMTimeValue((600 / fps).rounded())

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let width = Int(naturalSize.width)
        let height = Int(naturalSize.height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(Double(width * height) * fps * 0.15)]
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw ProcessingError.failed(writer.error?.localizedDescription ?? "Couldn't start writing.") }
        writer.startSession(atSourceTime: .zero)

        let chunk = 0.5
        var chunkEnd = end
        var written: CMTimeValue = 0
        let total = max(end - start, 0.01)
        while chunkEnd > start + 0.001 {
            try Task.checkCancellation()
            let chunkStart = max(start, chunkEnd - chunk)
            let reader = try AVAssetReader(asset: asset)
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ])
            reader.add(readerOutput)
            reader.timeRange = CMTimeRange(start: CompositionBuilder.time(max(0, chunkStart - 0.1)),
                                           end: CompositionBuilder.time(chunkEnd))
            guard reader.startReading() else { throw ProcessingError.failed("Couldn't read the clip.") }
            var frames: [CVPixelBuffer] = []
            while let sample = readerOutput.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if pts >= chunkStart - 0.000_1, pts < chunkEnd - 0.000_1, let buffer = CMSampleBufferGetImageBuffer(sample) {
                    frames.append(buffer)
                }
            }
            for buffer in frames.reversed() {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                adaptor.append(buffer, withPresentationTime: CMTime(value: written * frameValue, timescale: 600))
                written += 1
            }
            chunkEnd = chunkStart
            progress(min(0.99, (end - chunkEnd) / total))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed, written > 0 else {
            try? FileManager.default.removeItem(at: output)
            throw ProcessingError.failed(writer.error?.localizedDescription ?? "The reversed clip couldn't be written.")
        }
    }
}

/// Measures camera shake with Vision image registration and produces
/// per-frame correction offsets, which the compositor applies with a slight
/// zoom to hide the edges.
enum StabilizationService {
    static func analyze(source: URL, orientation: Int, start: Double, end: Double,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> [StabilizationSample] {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProcessingError.noVideo }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CompositionBuilder.time(start), end: CompositionBuilder.time(end))
        guard reader.startReading() else { throw ProcessingError.failed("Couldn't read the clip.") }

        var times: [Double] = []
        var path: [CGPoint] = []
        var previous: CIImage?
        var position = CGPoint.zero
        var analysisSize = CGSize(width: 1, height: 1)
        let total = max(end - start, 0.01)

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            var image = FrameRenderer.originAtZero(FrameRenderer.orient(CIImage(cvPixelBuffer: buffer), degrees: orientation))
            let scale = 320 / max(image.extent.width, 1)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            analysisSize = image.extent.size
            if let previous {
                let request = VNTranslationalImageRegistrationRequest(targetedCIImage: image)
                let handler = VNImageRequestHandler(ciImage: previous, options: [:])
                if (try? handler.perform([request])) != nil,
                   let observation = request.results?.first as? VNImageTranslationAlignmentObservation {
                    // The transform aligns the current frame to the previous one,
                    // so content moved by its inverse.
                    position.x -= observation.alignmentTransform.tx
                    position.y -= observation.alignmentTransform.ty
                }
            }
            previous = image
            times.append(time)
            path.append(position)
            progress(min(0.99, (time - start) / total))
        }
        guard path.count > 2 else { return [] }

        let radius = 15
        var samples: [StabilizationSample] = []
        samples.reserveCapacity(path.count)
        for index in path.indices {
            let lower = max(0, index - radius)
            let upper = min(path.count - 1, index + radius)
            var sum = CGPoint.zero
            for j in lower...upper {
                sum.x += path[j].x
                sum.y += path[j].y
            }
            let count = CGFloat(upper - lower + 1)
            let correctionX = sum.x / count - path[index].x
            let correctionY = sum.y / count - path[index].y
            // Store as fractions of the frame; y is stored top-down.
            samples.append(StabilizationSample(time: times[index],
                                               dx: Double(correctionX / analysisSize.width),
                                               dy: Double(-correctionY / analysisSize.height)))
        }
        return samples
    }
}

/// Basic noise reduction: a high-pass filter removes rumble and a smooth
/// noise gate lowers hiss and room tone between words.
enum NoiseReductionService {
    static func process(source: URL, start: Double, end: Double, output: URL,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        // Extract the trimmed audio to a plain file first.
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw ProcessingError.noAudio }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ProcessingError.failed("Audio couldn't be extracted.")
        }
        let extracted = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        session.outputURL = extracted
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(start: CompositionBuilder.time(start), end: CompositionBuilder.time(end))
        await session.export()
        guard session.status == .completed else {
            throw ProcessingError.failed(session.error?.localizedDescription ?? "Audio couldn't be extracted.")
        }
        defer { try? FileManager.default.removeItem(at: extracted) }
        progress(0.2)

        let inputFile = try AVAudioFile(forReading: extracted)
        let format = inputFile.processingFormat
        let channels = Int(format.channelCount)
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ProcessingError.failed("Not enough memory.")
        }

        // Pass 1: estimate the noise floor from quiet 20 ms windows.
        let window = max(1, Int(sampleRate * 0.02))
        var levels: [Float] = []
        while inputFile.framePosition < inputFile.length {
            try inputFile.read(into: buffer, frameCount: frameCount)
            guard let data = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength)
            var index = 0
            while index < frames {
                let upper = min(frames, index + window)
                var sum: Float = 0
                for channel in 0..<channels {
                    for i in index..<upper {
                        sum += data[channel][i] * data[channel][i]
                    }
                }
                levels.append(sqrt(sum / Float(max(1, (upper - index) * channels))))
                index = upper
            }
        }
        let sortedLevels = levels.sorted()
        let floor = sortedLevels.isEmpty ? 0 : sortedLevels[Int(Double(sortedLevels.count) * 0.1)]
        let threshold = max(floor * 2.5, 0.002)
        progress(0.5)

        // Pass 2: filter and gate, writing AAC.
        inputFile.framePosition = 0
        try? FileManager.default.removeItem(at: output)
        let outputFile = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 192_000
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        // 80 Hz high-pass biquad.
        let omega = 2 * Double.pi * 80 / sampleRate
        let alpha = sin(omega) / (2 * 0.707)
        let cosine = cos(omega)
        let a0 = 1 + alpha
        let b0 = Float((1 + cosine) / 2 / a0)
        let b1 = Float(-(1 + cosine) / a0)
        let b2 = b0
        let a1 = Float(-2 * cosine / a0)
        let a2 = Float((1 - alpha) / a0)
        var x1 = [Float](repeating: 0, count: channels)
        var x2 = x1
        var y1 = x1
        var y2 = x1
        var gain: Float = 1
        let attack = Float(1 - exp(-1 / (sampleRate * 0.005)))
        let release = Float(1 - exp(-1 / (sampleRate * 0.12)))
        let length = Double(max(inputFile.length, 1))

        while inputFile.framePosition < inputFile.length {
            try Task.checkCancellation()
            try inputFile.read(into: buffer, frameCount: frameCount)
            guard let data = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength)
            var index = 0
            while index < frames {
                let upper = min(frames, index + window)
                var sum: Float = 0
                for channel in 0..<channels {
                    for i in index..<upper {
                        let x = data[channel][i]
                        let y = b0 * x + b1 * x1[channel] + b2 * x2[channel] - a1 * y1[channel] - a2 * y2[channel]
                        x2[channel] = x1[channel]
                        x1[channel] = x
                        y2[channel] = y1[channel]
                        y1[channel] = y
                        data[channel][i] = y
                        sum += y * y
                    }
                }
                let level = sqrt(sum / Float(max(1, (upper - index) * channels)))
                let target: Float = level >= threshold ? 1 : max(0.08, pow(level / threshold, 2))
                for i in index..<upper {
                    gain += (target - gain) * (target > gain ? attack : release)
                    for channel in 0..<channels {
                        data[channel][i] *= gain
                    }
                }
                index = upper
            }
            try outputFile.write(from: buffer)
            progress(0.5 + 0.5 * Double(inputFile.framePosition) / length)
        }
    }
}
