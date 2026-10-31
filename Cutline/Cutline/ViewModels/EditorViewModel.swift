import AVFoundation
import Observation
import SwiftUI

enum EditorSheet: String, Identifiable {
    case text, audio, overlay, captions, filters, canvas, export
    case speed, volume, crop, animate, effects, trim, transition
    var id: String { rawValue }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct BusyState {
    var title: String
    var progress: Double?
}

enum TrimEdge {
    case leading, trailing
}

/// What "Copy Effects" carries between clips.
struct ClipLook: Equatable {
    var effects: ClipEffects
    var crop: CropSettings
    var fit: FitMode
}

/// The editor's single source of truth. Every edit goes through `mutate`,
/// which records undo, re-lays out the main track, autosaves and schedules
/// a preview rebuild off the main thread.
@MainActor
@Observable
final class EditorViewModel {
    private(set) var project: Project
    private(set) var playhead: Double = 0
    private(set) var pixelsPerSecond: Double = 64
    private(set) var selection: Selection?
    var activeSheet: EditorSheet?
    var showMediaPicker = false
    var busy: BusyState?
    var alert: AlertMessage?
    var showSafeArea = true
    var transitionClipID: UUID?
    var isDraggingItem = false
    var storageWarning: String?
    private(set) var copiedLook: ClipLook?
    private(set) var missingMedia: [String] = []
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var undoLabel: String?

    let playback: PlaybackController
    private let history = ProjectUndoManager()
    private let autosave: AutosaveService

    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var buildGeneration = 0
    @ObservationIgnored private var lastSnapTarget: Double?
    @ObservationIgnored private var dragOriginal: Project?
    @ObservationIgnored private var dragCandidates: [Double] = []
    @ObservationIgnored var busyTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false

    static let minimumPixelsPerSecond = 8.0
    static let maximumPixelsPerSecond = 600.0

    init(project: Project) {
        self.playback = PlaybackController()
        self.autosave = AutosaveService(store: .shared)
        self.project = project
        self.playhead = project.editor.playhead
        self.pixelsPerSecond = project.editor.pixelsPerSecond.clamped(EditorViewModel.minimumPixelsPerSecond...EditorViewModel.maximumPixelsPerSecond)
        self.selection = project.editor.selection
        validateSelection()
        autosave.snapshotProvider = { [weak self] in
            self?.snapshotForSaving()
        }
        autosave.thumbnailProvider = { project in
            let time = min(1, project.duration / 2)
            guard project.duration > 0,
                  let image = try? await ExportService.stillFrame(project: project, at: time, shortSide: 360) else { return nil }
            return image.jpegData(compressionQuality: 0.75)
        }
        autosave.onResult = { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.storageWarning = (error as? StoreError) == .lowStorage
                    ? "Storage is almost full. Your edits are kept and will save once space is freed."
                    : "Couldn't save: \(error.localizedDescription)"
            } else {
                self.storageWarning = nil
            }
        }
        playback.onTick = { [weak self] time in
            self?.playhead = time
        }
        scheduleRebuild()
    }

    // MARK: Derived

    var duration: Double { project.duration }

    var selectedVideoClip: VideoClip? {
        guard case .video(let id) = selection else { return nil }
        return project.videoClips.first { $0.id == id }
    }

    var selectedAudioClip: AudioClip? {
        guard case .audio(let id) = selection else { return nil }
        return project.audioClips.first { $0.id == id }
    }

    var selectedText: TextItem? {
        guard case .text(let id) = selection else { return nil }
        return project.texts.first { $0.id == id }
    }

    var selectedOverlay: OverlayItem? {
        guard case .overlay(let id) = selection else { return nil }
        return project.overlays.first { $0.id == id }
    }

    var selectedCaption: CaptionLine? {
        guard case .caption(let id) = selection else { return nil }
        return project.captions.lines.first { $0.id == id }
    }

    /// The main-track clip under the playhead.
    var clipAtPlayhead: VideoClip? {
        project.videoClips.first { playhead >= $0.startTime && playhead < $0.endTime }
    }

    func media(for id: UUID) -> MediaAsset? {
        project.media(id)
    }

    func mediaURL(_ asset: MediaAsset, preferProxy: Bool = false) -> URL {
        if preferProxy, let proxy = asset.proxyFileName {
            let url = ProjectStore.shared.mediaURL(projectID: project.id, fileName: proxy)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return ProjectStore.shared.mediaURL(projectID: project.id, fileName: asset.fileName)
    }

    // MARK: Change plumbing

    func mutate(_ label: String, coalescing key: String? = nil, _ change: (inout Project) -> Void) {
        let before = project.content
        let pushed = history.record(before, label: label, coalescingKey: key)
        var updated = project
        change(&updated)
        updated.layoutMainTrack()
        if pushed && updated.content == before {
            history.discardLast()
            refreshUndoState()
            return
        }
        project = updated
        afterChange()
    }

    /// Updates derived data (like detected beats) without an undo step.
    func applyWithoutUndo(_ change: (inout Project) -> Void) {
        var updated = project
        change(&updated)
        project = updated
        autosave.scheduleSave()
    }

    private func afterChange() {
        validateSelection()
        refreshUndoState()
        autosave.scheduleSave()
        scheduleRebuild()
    }

    private func refreshUndoState() {
        canUndo = history.canUndo
        canRedo = history.canRedo
        undoLabel = history.undoLabel
    }

    private func validateSelection() {
        guard let selection else { return }
        let exists: Bool
        switch selection {
        case .video(let id): exists = project.videoClips.contains { $0.id == id }
        case .audio(let id): exists = project.audioClips.contains { $0.id == id }
        case .text(let id): exists = project.texts.contains { $0.id == id }
        case .overlay(let id): exists = project.overlays.contains { $0.id == id }
        case .caption(let id): exists = project.captions.lines.contains { $0.id == id }
        }
        if !exists {
            self.selection = nil
        }
    }

    private func snapshotForSaving() -> Project {
        var copy = project
        copy.editor = EditorState(playhead: playhead, pixelsPerSecond: pixelsPerSecond, selection: selection)
        return copy
    }

    func undo() {
        guard let entry = history.undo(current: project.content) else { return }
        project.apply(entry.content)
        Haptics.light()
        afterChange()
    }

    func redo() {
        guard let entry = history.redo(current: project.content) else { return }
        project.apply(entry.content)
        Haptics.light()
        afterChange()
    }

    // MARK: Preview

    func scheduleRebuild() {
        buildGeneration += 1
        let generation = buildGeneration
        let snapshot = project
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            do {
                let build = try await CompositionBuilder.build(project: snapshot,
                                                               renderSize: CompositionBuilder.previewRenderSize(for: snapshot.canvas.aspect),
                                                               frameRate: 30, useProxies: true)
                guard let self, generation == self.buildGeneration, !self.isClosed else { return }
                self.missingMedia = build.missingMedia
                self.playback.load(build, structureKey: EditorViewModel.structureKey(snapshot), at: self.playhead)
            } catch {
                guard let self, generation == self.buildGeneration else { return }
                self.alert = AlertMessage(title: "Preview Problem", message: error.localizedDescription)
            }
        }
    }

    /// Changes to anything in this key need a new player item; other changes
    /// only swap the video composition.
    static func structureKey(_ project: Project) -> String {
        var parts: [String] = [project.canvas.aspect.rawValue, String(format: "%.3f", project.duration)]
        for clip in project.videoClips {
            parts.append("\(clip.id)|\(clip.mediaID)|\(clip.isImage)|\(clip.trimStart)|\(clip.trimEnd)|\(clip.startTime)|\(clip.speed.rate)|\(clip.speed.ramp.rawValue)|\(clip.isMuted)|\(clip.volume > 0)|\(clip.transitionOut.kind == .cut ? 0 : clip.transitionOut.duration)")
        }
        for clip in project.audioClips {
            parts.append("\(clip.id)|\(clip.mediaID)|\(clip.trimStart)|\(clip.trimEnd)|\(clip.startTime)|\(clip.isMuted)")
        }
        return parts.joined(separator: ";")
    }

    // MARK: Playback and timeline navigation

    func togglePlay() {
        if playback.isPlaying {
            playback.pause()
            autosave.scheduleSave()
        } else {
            playback.play(from: playhead)
        }
    }

    func scrub(to time: Double) {
        if playback.isPlaying {
            playback.pause()
        }
        let clamped = time.clamped(0...max(duration, 0))
        guard clamped != playhead else { return }
        playhead = clamped
        playback.seek(to: clamped)
    }

    func endScrub() {
        autosave.scheduleSave()
    }

    func setZoom(_ value: Double) {
        pixelsPerSecond = value.clamped(EditorViewModel.minimumPixelsPerSecond...EditorViewModel.maximumPixelsPerSecond)
    }

    func endZoom() {
        autosave.scheduleSave()
    }

    func select(_ newSelection: Selection?) {
        if selection != newSelection, newSelection != nil {
            Haptics.light()
        }
        selection = newSelection
        autosave.scheduleSave()
    }

    // MARK: Snapping

    private func snapCandidates(excluding id: UUID?) -> [Double] {
        var candidates: [Double] = [0, playhead]
        for clip in project.videoClips where clip.id != id {
            candidates.append(contentsOf: [clip.startTime, clip.endTime])
        }
        for clip in project.audioClips where clip.id != id {
            candidates.append(contentsOf: [clip.startTime, clip.endTime])
            candidates.append(contentsOf: clip.timelineBeats)
        }
        for item in project.texts where item.id != id {
            candidates.append(contentsOf: [item.startTime, item.endTime])
        }
        for item in project.overlays where item.id != id {
            candidates.append(contentsOf: [item.startTime, item.endTime])
        }
        return candidates
    }

    /// Snaps to the playhead, item edges and beats within 10 points.
    private func snap(_ time: Double) -> (Double, Bool) {
        let threshold = 10 / pixelsPerSecond
        var best: Double?
        var bestDistance = threshold
        for candidate in dragCandidates {
            let distance = abs(candidate - time)
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        if let best {
            if lastSnapTarget != best {
                Haptics.snap()
                lastSnapTarget = best
            }
            return (best, true)
        }
        lastSnapTarget = nil
        return (time, false)
    }

    // MARK: Item gestures (trim and move)

    func beginItemGesture(_ target: Selection) {
        if playback.isPlaying {
            playback.pause()
        }
        isDraggingItem = true
        dragOriginal = project
        dragCandidates = snapCandidates(excluding: target.id)
        lastSnapTarget = nil
        history.breakCoalescing()
        if selection != target {
            selection = target
        }
    }

    func endItemGesture() {
        isDraggingItem = false
        dragOriginal = nil
        lastSnapTarget = nil
        history.breakCoalescing()
    }

    /// Trims an item edge by `delta` seconds of timeline, measured from the
    /// start of the gesture.
    func trim(_ target: Selection, edge: TrimEdge, delta: Double) {
        guard let original = dragOriginal else { return }
        let key = "trim-\(target.id)"
        switch target {
        case .video(let id):
            guard let clip = original.videoClips.first(where: { $0.id == id }) else { return }
            let mediaDuration = original.media(clip.mediaID)?.duration ?? clip.trimEnd
            let rate = clip.isImage ? 1 : clip.sourceDuration / max(clip.duration, 0.001)
            let minimum = 0.1
            mutate("Trim", coalescing: key) { project in
                guard let index = project.videoClips.firstIndex(where: { $0.id == id }) else { return }
                if edge == .leading {
                    let (snapped, _) = snap(clip.startTime + delta)
                    var shift = snapped - clip.startTime
                    if clip.isImage {
                        shift = min(shift, clip.duration - minimum)
                        project.videoClips[index].trimEnd = clip.trimEnd - shift
                    } else {
                        let newTrimStart = (clip.trimStart + shift * rate).clamped(0...(clip.trimEnd - minimum))
                        shift = (newTrimStart - clip.trimStart) / rate
                        project.videoClips[index].trimStart = newTrimStart
                    }
                    if !project.isMagnetic {
                        project.videoClips[index].startTime = max(0, clip.startTime + shift)
                    }
                } else {
                    let (snapped, _) = snap(clip.endTime + delta)
                    let shift = snapped - clip.endTime
                    let upper = clip.isImage ? 3600 : mediaDuration
                    project.videoClips[index].trimEnd = (clip.trimEnd + shift * rate).clamped((clip.trimStart + minimum)...upper)
                }
            }
        case .audio(let id):
            guard let clip = original.audioClips.first(where: { $0.id == id }) else { return }
            let mediaDuration = original.media(clip.mediaID)?.duration ?? clip.trimEnd
            mutate("Trim", coalescing: key) { project in
                guard let index = project.audioClips.firstIndex(where: { $0.id == id }) else { return }
                if edge == .leading {
                    let (snapped, _) = snap(clip.startTime + delta)
                    let newTrimStart = (clip.trimStart + snapped - clip.startTime).clamped(0...(clip.trimEnd - 0.1))
                    let shift = newTrimStart - clip.trimStart
                    project.audioClips[index].trimStart = newTrimStart
                    project.audioClips[index].startTime = max(0, clip.startTime + shift)
                } else {
                    let (snapped, _) = snap(clip.endTime + delta)
                    project.audioClips[index].trimEnd = (clip.trimEnd + snapped - clip.endTime).clamped((clip.trimStart + 0.1)...mediaDuration)
                }
            }
        case .text(let id):
            guard let item = original.texts.first(where: { $0.id == id }) else { return }
            mutate("Trim", coalescing: key) { project in
                guard let index = project.texts.firstIndex(where: { $0.id == id }) else { return }
                let (start, end) = trimmedRange(start: item.startTime, end: item.endTime, edge: edge, delta: delta)
                project.texts[index].startTime = start
                project.texts[index].duration = end - start
            }
        case .overlay(let id):
            guard let item = original.overlays.first(where: { $0.id == id }) else { return }
            mutate("Trim", coalescing: key) { project in
                guard let index = project.overlays.firstIndex(where: { $0.id == id }) else { return }
                let (start, end) = trimmedRange(start: item.startTime, end: item.endTime, edge: edge, delta: delta)
                project.overlays[index].startTime = start
                project.overlays[index].duration = end - start
            }
        case .caption:
            break
        }
    }

    private func trimmedRange(start: Double, end: Double, edge: TrimEdge, delta: Double) -> (Double, Double) {
        if edge == .leading {
            let (snapped, _) = snap(start + delta)
            return (min(max(0, snapped), end - 0.2), end)
        }
        let (snapped, _) = snap(end + delta)
        return (start, max(snapped, start + 0.2))
    }

    /// Moves a non-main item (audio, text, overlay, caption line) during a drag.
    func move(_ target: Selection, delta: Double) {
        guard let original = dragOriginal else { return }
        func snappedStart(_ start: Double, _ duration: Double) -> Double {
            let (startSnap, didSnapStart) = snap(start + delta)
            if didSnapStart { return max(0, startSnap) }
            let (endSnap, didSnapEnd) = snap(start + duration + delta)
            if didSnapEnd { return max(0, endSnap - duration) }
            return max(0, start + delta)
        }
        let key = "move-\(target.id)"
        switch target {
        case .audio(let id):
            guard let clip = original.audioClips.first(where: { $0.id == id }) else { return }
            mutate("Move", coalescing: key) { project in
                if let index = project.audioClips.firstIndex(where: { $0.id == id }) {
                    project.audioClips[index].startTime = snappedStart(clip.startTime, clip.duration)
                }
            }
        case .text(let id):
            guard let item = original.texts.first(where: { $0.id == id }) else { return }
            mutate("Move", coalescing: key) { project in
                if let index = project.texts.firstIndex(where: { $0.id == id }) {
                    project.texts[index].startTime = snappedStart(item.startTime, item.duration)
                }
            }
        case .overlay(let id):
            guard let item = original.overlays.first(where: { $0.id == id }) else { return }
            mutate("Move", coalescing: key) { project in
                if let index = project.overlays.firstIndex(where: { $0.id == id }) {
                    project.overlays[index].startTime = snappedStart(item.startTime, item.duration)
                }
            }
        case .caption(let id):
            guard let line = original.captions.lines.first(where: { $0.id == id }) else { return }
            mutate("Move", coalescing: key) { project in
                guard let index = project.captions.lines.firstIndex(where: { $0.id == id }) else { return }
                let newStart = snappedStart(line.start, line.end - line.start)
                let shift = newStart - line.start
                for word in project.captions.lines[index].words.indices {
                    project.captions.lines[index].words[word].start = line.words[word].start + shift
                    project.captions.lines[index].words[word].end = line.words[word].end + shift
                }
            }
        case .video:
            break
        }
    }

    /// Drop of a long-press drag on the main track: reorder (magnetic) or
    /// reposition (free).
    func finishMainClipMove(_ id: UUID, delta: Double) {
        guard let original = dragOriginal,
              let clip = original.videoClips.first(where: { $0.id == id }) else { return }
        if original.isMagnetic {
            let center = clip.startTime + clip.duration / 2 + delta
            let others = original.videoClips.filter { $0.id != id }
            let newIndex = others.filter { $0.startTime + $0.duration / 2 < center }.count
            mutate("Reorder") { project in
                guard let from = project.videoClips.firstIndex(where: { $0.id == id }) else { return }
                let moved = project.videoClips.remove(at: from)
                project.videoClips.insert(moved, at: min(newIndex, project.videoClips.count))
            }
        } else {
            let (snapped, _) = snap(clip.startTime + delta)
            mutate("Move") { project in
                guard let index = project.videoClips.firstIndex(where: { $0.id == id }) else { return }
                project.videoClips[index].startTime = max(0, snapped)
                project.videoClips.sort { $0.startTime < $1.startTime }
            }
        }
        Haptics.medium()
    }

    // MARK: Split, delete, duplicate

    func splitAtPlayhead() {
        let time = playhead
        switch selection {
        case .audio(let id):
            mutate("Split") { project in
                guard let index = project.audioClips.firstIndex(where: { $0.id == id }) else { return }
                let clip = project.audioClips[index]
                guard time > clip.startTime + 0.05, time < clip.endTime - 0.05 else { return }
                var second = clip
                second.id = UUID()
                let sourceSplit = clip.trimStart + (time - clip.startTime)
                project.audioClips[index].trimEnd = sourceSplit
                project.audioClips[index].fadeOut = 0
                second.trimStart = sourceSplit
                second.startTime = time
                second.fadeIn = 0
                project.audioClips.insert(second, at: index + 1)
            }
        case .text(let id):
            mutate("Split") { project in
                guard let index = project.texts.firstIndex(where: { $0.id == id }) else { return }
                let item = project.texts[index]
                guard time > item.startTime + 0.05, time < item.endTime - 0.05 else { return }
                var second = item
                second.id = UUID()
                second.startTime = time
                second.duration = item.endTime - time
                second.keyframes = item.keyframes.filter { $0.time > time - item.startTime }
                    .map { var k = $0; k.time -= time - item.startTime; return k }
                project.texts[index].duration = time - item.startTime
                project.texts.insert(second, at: index + 1)
            }
        case .overlay(let id):
            mutate("Split") { project in
                guard let index = project.overlays.firstIndex(where: { $0.id == id }) else { return }
                let item = project.overlays[index]
                guard time > item.startTime + 0.05, time < item.endTime - 0.05 else { return }
                var second = item
                second.id = UUID()
                second.startTime = time
                second.duration = item.endTime - time
                second.keyframes = item.keyframes.filter { $0.time > time - item.startTime }
                    .map { var k = $0; k.time -= time - item.startTime; return k }
                project.overlays[index].duration = time - item.startTime
                project.overlays.insert(second, at: index + 1)
            }
        default:
            let id: UUID?
            if case .video(let selected) = selection {
                id = selected
            } else {
                id = clipAtPlayhead?.id
            }
            guard let id else { return }
            var newID: UUID?
            mutate("Split") { project in
                newID = EditorViewModel.splitVideo(&project, clipID: id, at: time)
            }
            if newID != nil {
                Haptics.medium()
            }
        }
    }

    /// Splits a main-track clip, returning the second piece's ID.
    static func splitVideo(_ project: inout Project, clipID: UUID, at time: Double) -> UUID? {
        guard let index = project.videoClips.firstIndex(where: { $0.id == clipID }) else { return nil }
        let clip = project.videoClips[index]
        guard time > clip.startTime + 0.05, time < clip.endTime - 0.05 else { return nil }
        let local = time - clip.startTime
        let sourceSplit = clip.sourceTime(atTimeline: time)
        var first = clip
        var second = clip
        second.id = UUID()
        first.trimEnd = sourceSplit
        first.transitionOut = Transition()
        first.fadeOut = 0
        second.trimStart = sourceSplit
        second.startTime = time
        second.fadeIn = 0
        first.keyframes = clip.keyframes.filter { $0.time <= local }
        second.keyframes = clip.keyframes.filter { $0.time > local }.map { var k = $0; k.time -= local; return k }
        if !clip.keyframes.isEmpty {
            let boundary = KeyframeMath.value(base: clip.transform, keyframes: clip.keyframes, at: local)
            first.keyframes.append(Keyframe(time: local, values: boundary))
            second.keyframes.insert(Keyframe(time: 0, values: boundary), at: 0)
        }
        project.videoClips[index] = first
        project.videoClips.insert(second, at: index + 1)
        return second.id
    }

    func deleteSelection() {
        guard let selection else { return }
        mutate("Delete") { project in
            switch selection {
            case .video(let id): project.videoClips.removeAll { $0.id == id }
            case .audio(let id): project.audioClips.removeAll { $0.id == id }
            case .text(let id): project.texts.removeAll { $0.id == id }
            case .overlay(let id): project.overlays.removeAll { $0.id == id }
            case .caption(let id): project.captions.lines.removeAll { $0.id == id }
            }
        }
        self.selection = nil
        Haptics.medium()
    }

    func duplicateSelection() {
        guard let selection else { return }
        var newSelection: Selection?
        mutate("Duplicate") { project in
            switch selection {
            case .video(let id):
                guard let index = project.videoClips.firstIndex(where: { $0.id == id }) else { return }
                var copy = project.videoClips[index]
                copy.id = UUID()
                copy.startTime = copy.endTime
                project.videoClips.insert(copy, at: index + 1)
                newSelection = .video(copy.id)
            case .audio(let id):
                guard let clip = project.audioClips.first(where: { $0.id == id }) else { return }
                var copy = clip
                copy.id = UUID()
                copy.startTime = clip.endTime
                project.audioClips.append(copy)
                newSelection = .audio(copy.id)
            case .text(let id):
                guard let item = project.texts.first(where: { $0.id == id }) else { return }
                var copy = item
                copy.id = UUID()
                copy.startTime = item.endTime
                project.texts.append(copy)
                newSelection = .text(copy.id)
            case .overlay(let id):
                guard let item = project.overlays.first(where: { $0.id == id }) else { return }
                var copy = item
                copy.id = UUID()
                copy.startTime = item.endTime
                project.overlays.append(copy)
                newSelection = .overlay(copy.id)
            case .caption:
                break
            }
        }
        if let newSelection {
            self.selection = newSelection
        }
    }

    // MARK: Item updates

    func updateVideoClip(_ id: UUID, _ label: String, coalescing key: String? = nil, _ change: (inout VideoClip) -> Void) {
        mutate(label, coalescing: key.map { "\($0)-\(id)" }) { project in
            if let index = project.videoClips.firstIndex(where: { $0.id == id }) {
                change(&project.videoClips[index])
            }
        }
    }

    func updateAudioClip(_ id: UUID, _ label: String, coalescing key: String? = nil, _ change: (inout AudioClip) -> Void) {
        mutate(label, coalescing: key.map { "\($0)-\(id)" }) { project in
            if let index = project.audioClips.firstIndex(where: { $0.id == id }) {
                change(&project.audioClips[index])
            }
        }
    }

    func updateText(_ id: UUID, _ label: String, coalescing key: String? = nil, _ change: (inout TextItem) -> Void) {
        mutate(label, coalescing: key.map { "\($0)-\(id)" }) { project in
            if let index = project.texts.firstIndex(where: { $0.id == id }) {
                change(&project.texts[index])
            }
        }
    }

    func updateOverlay(_ id: UUID, _ label: String, coalescing key: String? = nil, _ change: (inout OverlayItem) -> Void) {
        mutate(label, coalescing: key.map { "\($0)-\(id)" }) { project in
            if let index = project.overlays.firstIndex(where: { $0.id == id }) {
                change(&project.overlays[index])
            }
        }
    }

    func setTransition(after clipID: UUID, _ transition: Transition) {
        updateVideoClip(clipID, "Transition", coalescing: "transition") { $0.transitionOut = transition }
    }

    // MARK: Text, overlays, captions

    func addText() {
        let item = TextItem(text: "Your text", startTime: playhead, duration: 3)
        mutate("Add Text") { $0.texts.append(item) }
        selection = .text(item.id)
        activeSheet = .text
    }

    func addOverlay(_ content: OverlayContent) {
        let item = OverlayItem(content: content, startTime: playhead, duration: 3,
                               size: { if case .image = content { return 0.5 } else { return 0.3 } }())
        mutate("Add Overlay") { $0.overlays.append(item) }
        selection = .overlay(item.id)
        Haptics.light()
    }

    func updateCaptionText(_ lineID: UUID, text: String) {
        mutate("Edit Caption", coalescing: "caption-\(lineID)") { project in
            guard let index = project.captions.lines.firstIndex(where: { $0.id == lineID }) else { return }
            project.captions.lines[index].setText(text)
            if project.captions.lines[index].words.isEmpty {
                project.captions.lines.remove(at: index)
            }
        }
    }

    func setCaptionStyle(_ style: CaptionStyle) {
        mutate("Caption Style") { $0.captions.style = style }
    }

    func setCaptionFont(_ font: FontChoice) {
        mutate("Caption Font") { $0.captions.font = font }
    }

    func removeAllCaptions() {
        mutate("Remove Captions") { $0.captions.lines = [] }
    }

    // MARK: Transform keyframes

    struct TransformContext {
        var base: TransformValues
        var keyframes: [Keyframe]
        var localTime: Double
        var duration: Double
    }

    func transformContext(for target: Selection?) -> TransformContext? {
        switch target {
        case .video(let id):
            guard let clip = project.videoClips.first(where: { $0.id == id }) else { return nil }
            return TransformContext(base: clip.transform, keyframes: clip.keyframes, localTime: playhead - clip.startTime, duration: clip.duration)
        case .text(let id):
            guard let item = project.texts.first(where: { $0.id == id }) else { return nil }
            return TransformContext(base: item.transform, keyframes: item.keyframes, localTime: playhead - item.startTime, duration: item.duration)
        case .overlay(let id):
            guard let item = project.overlays.first(where: { $0.id == id }) else { return nil }
            return TransformContext(base: item.transform, keyframes: item.keyframes, localTime: playhead - item.startTime, duration: item.duration)
        default:
            return nil
        }
    }

    /// Edits the transform at the playhead: the keyframe there if the item is
    /// animated, otherwise the item's static transform.
    func setTransform(_ values: TransformValues, for target: Selection) {
        guard let context = transformContext(for: target) else { return }
        let local = context.localTime.clamped(0...max(context.duration, 0))
        modifyTransform(target, label: "Adjust Transform", coalescing: "transform") { base, keyframes in
            if keyframes.isEmpty {
                base = values
            } else if let index = keyframes.firstIndex(where: { abs($0.time - local) < 1.0 / 30 }) {
                keyframes[index].values = values
            } else {
                keyframes.append(Keyframe(time: local, values: values))
                keyframes.sort { $0.time < $1.time }
            }
        }
    }

    func addKeyframe(for target: Selection) {
        guard let context = transformContext(for: target) else { return }
        let local = context.localTime.clamped(0...max(context.duration, 0))
        let current = KeyframeMath.value(base: context.base, keyframes: context.keyframes, at: local)
        modifyTransform(target, label: "Add Keyframe") { _, keyframes in
            keyframes.removeAll { abs($0.time - local) < 1.0 / 30 }
            keyframes.append(Keyframe(time: local, values: current))
            keyframes.sort { $0.time < $1.time }
        }
        Haptics.light()
    }

    func removeKeyframe(_ keyframeID: UUID, for target: Selection) {
        modifyTransform(target, label: "Remove Keyframe") { base, keyframes in
            if let removed = keyframes.first(where: { $0.id == keyframeID }), keyframes.count == 1 {
                base = removed.values
            }
            keyframes.removeAll { $0.id == keyframeID }
        }
    }

    func setKeyframeEasing(_ keyframeID: UUID, easing: Easing, for target: Selection) {
        modifyTransform(target, label: "Easing") { _, keyframes in
            if let index = keyframes.firstIndex(where: { $0.id == keyframeID }) {
                keyframes[index].easing = easing
            }
        }
    }

    func resetTransform(for target: Selection) {
        modifyTransform(target, label: "Reset Transform") { base, keyframes in
            base = .identity
            keyframes = []
        }
    }

    private func modifyTransform(_ target: Selection, label: String, coalescing key: String? = nil,
                                 _ change: (inout TransformValues, inout [Keyframe]) -> Void) {
        switch target {
        case .video(let id):
            updateVideoClip(id, label, coalescing: key) { change(&$0.transform, &$0.keyframes) }
        case .text(let id):
            updateText(id, label, coalescing: key) { change(&$0.transform, &$0.keyframes) }
        case .overlay(let id):
            updateOverlay(id, label, coalescing: key) { change(&$0.transform, &$0.keyframes) }
        default:
            break
        }
    }

    // MARK: Effects clipboard

    func copyLook() {
        guard let clip = selectedVideoClip else { return }
        copiedLook = ClipLook(effects: clip.effects, crop: clip.crop, fit: clip.fit)
        Haptics.light()
    }

    func pasteLook() {
        guard let look = copiedLook, let clip = selectedVideoClip else { return }
        updateVideoClip(clip.id, "Paste Effects") { target in
            target.effects = look.effects
            target.crop = look.crop
            target.fit = look.fit
        }
        Haptics.success()
    }

    func applyEffectsToAllClips(_ effects: ClipEffects) {
        mutate("Apply to All") { project in
            for index in project.videoClips.indices {
                project.videoClips[index].effects = effects
            }
        }
    }

    // MARK: Canvas and project settings

    func setAspect(_ aspect: AspectRatio) {
        mutate("Canvas") { $0.canvas.aspect = aspect }
    }

    func setBackground(_ background: CanvasBackground) {
        mutate("Background") { $0.canvas.background = background }
    }

    func setMagnetic(_ isOn: Bool) {
        mutate("Magnetic Timeline") { $0.isMagnetic = isOn }
    }

    func setGlobalEffects(_ effects: ClipEffects) {
        mutate("Filters", coalescing: "global-effects") { $0.globalEffects = effects }
    }

    // MARK: Lifecycle

    func flushSave() {
        autosave.flush(synchronously: true)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        busyTask?.cancel()
        rebuildTask?.cancel()
        playback.pause()
        autosave.scheduleSave()
        autosave.flush(synchronously: true)
        playback.teardown()
        NotificationCenter.default.post(name: .cutlineProjectsDidChange, object: nil)
    }

    /// A copy for export with the current editor state.
    var exportSnapshot: Project {
        snapshotForSaving()
    }

    func notifyEditorStateChanged() {
        autosave.scheduleSave()
    }
}
