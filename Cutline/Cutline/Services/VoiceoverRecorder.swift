import AVFoundation
import Observation

/// Records voiceovers with the microphone.
@MainActor
@Observable
final class VoiceoverRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: Double = 0
    private(set) var level: Double = 0

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTask: Task<Void, Never>?

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ])
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw ProcessingError.failed("Recording couldn't start. Another app may be using the microphone.")
        }
        self.recorder = recorder
        isRecording = true
        elapsed = 0
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.elapsed = recorder.currentTime
                let power = Double(recorder.averagePower(forChannel: 0))
                self.level = max(0, min(1, (power + 50) / 50))
            }
        }
    }

    /// Stops recording and returns the recorded duration.
    @discardableResult
    func stop() -> Double {
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop()
        recorder = nil
        meterTask?.cancel()
        meterTask = nil
        isRecording = false
        level = 0
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        return duration
    }

    func cancel(deleting url: URL) {
        stop()
        try? FileManager.default.removeItem(at: url)
    }
}
