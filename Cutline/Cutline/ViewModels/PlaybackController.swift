import AVFoundation
import Observation

/// Owns the AVPlayer used for the preview. Seeks are coalesced so scrubbing
/// stays instant: while one seek is in flight only the latest request is kept.
@MainActor
@Observable
final class PlaybackController {
    let player = AVPlayer()
    private(set) var isPlaying = false

    @ObservationIgnored var onTick: ((Double) -> Void)?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var structureKey: String?
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private(set) var duration: Double = 0

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.onTick?(time.seconds)
            }
        }
    }

    func teardown() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    /// Shows a newly built composition. If only effects, text or overlays
    /// changed, the current item is kept and only its video composition and
    /// audio mix are swapped, which avoids any flicker.
    func load(_ build: BuildResult, structureKey key: String, at time: Double) {
        duration = build.duration
        if key == structureKey, let item = player.currentItem {
            item.videoComposition = build.videoComposition
            item.audioMix = build.audioMix
            if !isPlaying {
                seek(to: time)
            }
            return
        }
        structureKey = key
        let item = AVPlayerItem(asset: build.composition)
        item.videoComposition = build.videoComposition
        item.audioMix = build.audioMix
        item.audioTimePitchAlgorithm = .spectral
        item.seekingWaitsForVideoCompositionRendering = true
        let wasPlaying = isPlaying
        player.replaceCurrentItem(with: item)
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.onTick?(self.duration)
            }
        }
        seekInFlight = false
        pendingSeek = nil
        seek(to: time)
        if wasPlaying {
            player.play()
        }
    }

    func play(from time: Double) {
        let start = time >= duration - 0.05 ? 0 : time
        if start != time {
            onTick?(start)
        }
        player.seek(to: CompositionBuilder.time(start), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.player.play()
            }
        }
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        if seekInFlight {
            pendingSeek = seconds
            return
        }
        seekInFlight = true
        player.seek(to: CompositionBuilder.time(seconds), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.seek(to: next)
                }
            }
        }
    }
}
