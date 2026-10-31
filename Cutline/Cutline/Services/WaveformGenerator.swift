import AVFoundation
import Foundation

/// Reads audio off the main thread and produces a loudness envelope
/// (100 values per second, 0...1) used for waveforms and beat detection.
actor WaveformGenerator {
    static let shared = WaveformGenerator()
    static let samplesPerSecond = 100

    private var memory: [URL: [Float]] = [:]
    private var inFlight: [URL: Task<[Float], Never>] = [:]

    func envelope(url: URL) async -> [Float] {
        if let cached = memory[url] {
            return cached
        }
        if let task = inFlight[url] {
            return await task.value
        }
        let task = Task.detached(priority: .utility) {
            await WaveformGenerator.computeEnvelope(url: url)
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        memory[url] = result
        return result
    }

    private static func computeEnvelope(url: URL) async -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try? await asset.loadTracks(withMediaType: .audio).first
        guard let audioTrack = track, let reader = try? AVAssetReader(asset: asset) else { return [] }
        let sampleRate = 8000
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let window = sampleRate / samplesPerSecond
        var envelope: [Float] = []
        var accumulator: Float = 0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Int16](repeating: 0, count: length / 2)
            data.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
                }
            }
            for sample in data {
                let value = Float(sample) / Float(Int16.max)
                accumulator += value * value
                count += 1
                if count == window {
                    envelope.append(sqrt(accumulator / Float(window)))
                    accumulator = 0
                    count = 0
                }
            }
        }
        if count > 0 {
            envelope.append(sqrt(accumulator / Float(count)))
        }
        let peak = envelope.max() ?? 0
        guard peak > 0 else { return envelope }
        return envelope.map { min(1, $0 / peak) }
    }

    /// Onset-based beat detection: rises in loudness well above the local
    /// average, at least 0.25 s apart. Returns times in seconds.
    static func detectBeats(envelope: [Float]) -> [Double] {
        guard envelope.count > 20 else { return [] }
        var flux = [Float](repeating: 0, count: envelope.count)
        for index in 1..<envelope.count {
            flux[index] = max(0, envelope[index] - envelope[index - 1])
        }
        let radius = 50
        var beats: [Double] = []
        var lastBeat = -Double.infinity
        for index in 1..<(flux.count - 1) {
            let lower = max(0, index - radius)
            let upper = min(flux.count - 1, index + radius)
            var sum: Float = 0
            var sumSquares: Float = 0
            for j in lower...upper {
                sum += flux[j]
                sumSquares += flux[j] * flux[j]
            }
            let n = Float(upper - lower + 1)
            let mean = sum / n
            let deviation = sqrt(max(0, sumSquares / n - mean * mean))
            let threshold = mean + 1.5 * deviation + 0.01
            let isPeak = flux[index] > threshold && flux[index] >= flux[index - 1] && flux[index] >= flux[index + 1]
            let time = Double(index) / Double(samplesPerSecond)
            if isPeak && time - lastBeat >= 0.25 {
                beats.append(time)
                lastBeat = time
            }
        }
        return beats
    }
}
