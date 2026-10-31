import AVFoundation
import PhotosUI
import SwiftUI

/// Long-running editor operations. Each runs off the main thread behind a
/// cancellable progress HUD and applies its result as one undoable edit.
extension EditorViewModel {
    func runBusy(_ title: String, failureTitle: String,
                 _ work: @escaping @MainActor (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void) {
        guard busy == nil else { return }
        if playback.isPlaying {
            playback.pause()
        }
        busy = BusyState(title: title, progress: nil)
        busyTask = Task { [weak self] in
            let progress: @Sendable (Double) -> Void = { value in
                Task { @MainActor in
                    self?.busy?.progress = value
                }
            }
            do {
                try await work(progress)
            } catch is CancellationError {
                // Cancelled by the user.
            } catch {
                self?.alert = AlertMessage(title: failureTitle, message: error.localizedDescription)
            }
            self?.busy = nil
        }
    }

    func cancelBusy() {
        busyTask?.cancel()
    }

    private var projectID: UUID { project.id }

    // MARK: Importing

    func importPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let projectID = self.projectID
        let noun = items.count == 1 ? "item" : "items"
        runBusy("Importing \(items.count) \(noun)…", failureTitle: "Import Failed") { [weak self] _ in
            let result = await MediaImportService.shared.importPickerItems(items, projectID: projectID)
            guard let self else { return }
            self.appendToMainTrack(result.assets)
            if !result.failures.isEmpty {
                self.alert = AlertMessage(title: "Some Items Weren't Added", message: result.failures.joined(separator: "\n"))
            }
        }
    }

    /// Adds videos and photos to the end of the main track.
    func appendToMainTrack(_ assets: [MediaAsset]) {
        let visual = assets.filter { $0.kind != .audio }
        guard !visual.isEmpty else { return }
        let wasEmpty = project.videoClips.isEmpty
        var lastID: UUID?
        mutate("Add Media") { project in
            project.media.append(contentsOf: assets)
            for asset in visual {
                let clip = VideoClip(mediaID: asset.id, isImage: asset.kind == .image, trimStart: 0,
                                     trimEnd: asset.kind == .image ? 3 : asset.duration,
                                     startTime: project.videoClips.last?.endTime ?? 0,
                                     fit: asset.kind == .image ? .fill : .fit)
                project.videoClips.append(clip)
                lastID = clip.id
            }
        }
        if wasEmpty {
            scrub(to: 0)
        } else if let lastID {
            select(.video(lastID))
        }
        Haptics.success()
    }

    func importMusic(from url: URL) {
        let projectID = self.projectID
        let start = playhead
        runBusy("Adding music…", failureTitle: "Music Couldn't Be Added") { [weak self] progress in
            let asset = try await MediaImportService.shared.importFile(at: url, projectID: projectID)
            guard asset.hasAudio else { throw ProcessingError.noAudio }
            guard let self else { return }
            let clip = AudioClip(mediaID: asset.id, role: .music, trimStart: 0, trimEnd: asset.duration, startTime: start)
            self.mutate("Add Music") { project in
                project.media.append(asset)
                project.audioClips.append(clip)
            }
            self.select(.audio(clip.id))
            progress(0.7)
            let envelope = await WaveformGenerator.shared.envelope(url: self.mediaURL(asset))
            let beats = WaveformGenerator.detectBeats(envelope: envelope)
            self.applyWithoutUndo { project in
                if let index = project.audioClips.firstIndex(where: { $0.id == clip.id }) {
                    project.audioClips[index].beats = beats
                }
            }
        }
    }

    func addVoiceover(fileName: String, startTime: Double) {
        let projectID = self.projectID
        runBusy("Adding voiceover…", failureTitle: "Voiceover Couldn't Be Added") { [weak self] _ in
            let asset = try await MediaImportService.shared.registerGeneratedFile(fileName: fileName, projectID: projectID,
                                                                                  displayName: "Voiceover")
            guard let self else { return }
            let clip = AudioClip(mediaID: asset.id, role: .voiceover, trimStart: 0, trimEnd: asset.duration, startTime: startTime)
            self.mutate("Record Voiceover") { project in
                project.media.append(asset)
                project.audioClips.append(clip)
            }
            self.select(.audio(clip.id))
        }
    }

    func addImageOverlay(_ item: PhotosPickerItem) {
        let projectID = self.projectID
        runBusy("Adding image…", failureTitle: "Image Couldn't Be Added") { [weak self] _ in
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                throw ImportError.unsupportedFormat("That image")
            }
            let asset = try MediaImportService.shared.importImage(image, projectID: projectID, displayName: "Overlay")
            guard let self else { return }
            self.mutate("Add Image") { $0.media.append(asset) }
            self.addOverlay(.image(asset.id))
        }
    }

    // MARK: Clip processing

    func freezeFrame() {
        let target = selectedVideoClip ?? clipAtPlayhead
        guard let clip = target, !clip.isImage, let media = media(for: clip.mediaID) else {
            alert = AlertMessage(title: "Freeze Frame", message: "Move the playhead over a video clip first.")
            return
        }
        let time = playhead.clamped(clip.startTime...max(clip.startTime, clip.endTime - 0.01))
        let sourceTime = clip.sourceTime(atTimeline: time)
        let url = mediaURL(media)
        let projectID = self.projectID
        runBusy("Freezing frame…", failureTitle: "Freeze Frame Failed") { [weak self] _ in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let (cgImage, _) = try await generator.image(at: CompositionBuilder.time(sourceTime))
            let still = try MediaImportService.shared.importImage(UIImage(cgImage: cgImage), projectID: projectID,
                                                                 displayName: "Freeze Frame")
            guard let self else { return }
            var freezeID: UUID?
            self.mutate("Freeze Frame") { project in
                project.media.append(still)
                var frozen = VideoClip(mediaID: still.id, isImage: true, trimStart: 0, trimEnd: 2, startTime: time)
                frozen.crop = clip.crop
                frozen.fit = clip.fit
                frozen.effects = clip.effects
                frozen.transform = KeyframeMath.value(base: clip.transform, keyframes: clip.keyframes, at: time - clip.startTime)
                freezeID = frozen.id
                if let secondID = EditorViewModel.splitVideo(&project, clipID: clip.id, at: time),
                   let index = project.videoClips.firstIndex(where: { $0.id == secondID }) {
                    project.videoClips.insert(frozen, at: index)
                } else if let index = project.videoClips.firstIndex(where: { $0.id == clip.id }) {
                    let after = time >= clip.endTime - 0.06
                    project.videoClips.insert(frozen, at: after ? index + 1 : index)
                }
            }
            if let freezeID {
                self.select(.video(freezeID))
            }
        }
    }

    func reverseSelectedClip() {
        guard let clip = selectedVideoClip, !clip.isImage, let media = media(for: clip.mediaID) else { return }
        let source = mediaURL(media)
        let projectID = self.projectID
        let fileName = "\(UUID().uuidString)-reversed.mp4"
        let output = ProjectStore.shared.mediaURL(projectID: projectID, fileName: fileName)
        let end = min(clip.trimEnd, media.duration)
        runBusy("Reversing clip…", failureTitle: "Reverse Failed") { [weak self] progress in
            do {
                try ProjectStore.shared.ensureSpace(bytes: Int64(media.width * media.height * 4 * (end - clip.trimStart)))
            } catch {
                throw ImportError.lowStorage
            }
            try await ReverseService.reverse(source: source, start: clip.trimStart, end: end, output: output, progress: progress)
            var asset = try await MediaImportService.shared.registerGeneratedFile(fileName: fileName, projectID: projectID,
                                                                                  displayName: "\(media.displayName) (Reversed)")
            asset.hasAudio = false
            guard let self else { return }
            self.updateVideoClip(clip.id, "Reverse") { target in
                target.mediaID = asset.id
                target.trimStart = 0
                target.trimEnd = asset.duration
                target.isReversed.toggle()
                target.stabilization = nil
            }
            self.mutate("Reverse") { $0.media.append(asset) }
            self.alert = AlertMessage(title: "Clip Reversed", message: "Reversed clips play without their original sound. Detach the audio first if you need it.")
        }
    }

    func toggleStabilization() {
        guard let clip = selectedVideoClip, !clip.isImage, let media = media(for: clip.mediaID) else { return }
        if clip.stabilization != nil {
            updateVideoClip(clip.id, "Stabilization Off") { $0.stabilization = nil }
            return
        }
        let source = mediaURL(media)
        runBusy("Stabilizing…", failureTitle: "Stabilization Failed") { [weak self] progress in
            let samples = try await StabilizationService.analyze(source: source, orientation: media.orientation,
                                                                 start: clip.trimStart, end: clip.trimEnd, progress: progress)
            guard let self else { return }
            guard !samples.isEmpty else {
                throw ProcessingError.failed("This clip is too short to stabilize.")
            }
            self.updateVideoClip(clip.id, "Stabilize") { $0.stabilization = samples }
        }
    }

    func detachAudio() {
        guard let clip = selectedVideoClip, !clip.isImage, let media = media(for: clip.mediaID) else { return }
        guard media.hasAudio, !clip.isMuted else {
            alert = AlertMessage(title: "No Audio", message: "This clip has no audio to detach.")
            return
        }
        guard clip.speed.isNormal else {
            alert = AlertMessage(title: "Detach Audio", message: "Set the clip's speed back to 1× before detaching its audio.")
            return
        }
        let audio = AudioClip(mediaID: clip.mediaID, role: .extracted, trimStart: clip.trimStart, trimEnd: clip.trimEnd,
                              startTime: clip.startTime, volume: clip.volume, fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
        mutate("Detach Audio") { project in
            project.audioClips.append(audio)
            if let index = project.videoClips.firstIndex(where: { $0.id == clip.id }) {
                project.videoClips[index].isMuted = true
            }
        }
        select(.audio(audio.id))
    }

    /// Noise reduction for an audio clip, or for a video clip's audio (which
    /// is detached into a cleaned audio clip).
    func cleanAudio() {
        let projectID = self.projectID
        let fileName = "\(UUID().uuidString)-clean.m4a"
        let output = ProjectStore.shared.mediaURL(projectID: projectID, fileName: fileName)
        if let clip = selectedAudioClip, let media = media(for: clip.mediaID) {
            let source = mediaURL(media)
            runBusy("Reducing noise…", failureTitle: "Noise Reduction Failed") { [weak self] progress in
                try await NoiseReductionService.process(source: source, start: clip.trimStart, end: clip.trimEnd,
                                                        output: output, progress: progress)
                let asset = try await MediaImportService.shared.registerGeneratedFile(fileName: fileName, projectID: projectID,
                                                                                      displayName: "\(media.displayName) (Clean)")
                guard let self else { return }
                self.mutate("Reduce Noise") { project in
                    project.media.append(asset)
                    if let index = project.audioClips.firstIndex(where: { $0.id == clip.id }) {
                        let offset = clip.trimStart
                        project.audioClips[index].mediaID = asset.id
                        project.audioClips[index].trimStart = 0
                        project.audioClips[index].trimEnd = asset.duration
                        project.audioClips[index].beats = clip.beats.map { $0 - offset }.filter { $0 >= 0 }
                    }
                }
            }
        } else if let clip = selectedVideoClip, !clip.isImage, let media = media(for: clip.mediaID) {
            guard media.hasAudio, !clip.isMuted else {
                alert = AlertMessage(title: "No Audio", message: "This clip has no audio to clean.")
                return
            }
            guard clip.speed.isNormal else {
                alert = AlertMessage(title: "Clean Audio", message: "Set the clip's speed back to 1× before cleaning its audio.")
                return
            }
            let source = mediaURL(media)
            runBusy("Reducing noise…", failureTitle: "Noise Reduction Failed") { [weak self] progress in
                try await NoiseReductionService.process(source: source, start: clip.trimStart, end: clip.trimEnd,
                                                        output: output, progress: progress)
                let asset = try await MediaImportService.shared.registerGeneratedFile(fileName: fileName, projectID: projectID,
                                                                                      displayName: "\(media.displayName) (Clean)")
                guard let self else { return }
                let audio = AudioClip(mediaID: asset.id, role: .extracted, trimStart: 0, trimEnd: asset.duration,
                                      startTime: clip.startTime, volume: clip.volume, fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
                self.mutate("Clean Audio") { project in
                    project.media.append(asset)
                    project.audioClips.append(audio)
                    if let index = project.videoClips.firstIndex(where: { $0.id == clip.id }) {
                        project.videoClips[index].isMuted = true
                    }
                }
                self.select(.audio(audio.id))
            }
        }
    }

    func detectBeats() {
        guard let clip = selectedAudioClip, let media = media(for: clip.mediaID) else { return }
        let url = mediaURL(media)
        runBusy("Finding beats…", failureTitle: "Beat Detection Failed") { [weak self] _ in
            let envelope = await WaveformGenerator.shared.envelope(url: url)
            let beats = WaveformGenerator.detectBeats(envelope: envelope)
            guard let self else { return }
            self.updateAudioClip(clip.id, "Detect Beats") { $0.beats = beats }
            let count = beats.filter { $0 >= clip.trimStart && $0 <= clip.trimEnd }.count
            self.alert = AlertMessage(title: "Beats Found",
                                      message: count == 0 ? "No clear beats were found." : "\(count) beat markers were added. Cuts and clips now snap to them.")
        }
    }

    func generateCaptions() {
        let snapshot = project
        runBusy("Listening for speech…", failureTitle: "Captions Unavailable") { [weak self] _ in
            let lines = try await CaptionService.generate(for: snapshot)
            guard let self else { return }
            self.mutate("Auto Captions") { $0.captions.lines = lines }
            Haptics.success()
        }
    }
}
