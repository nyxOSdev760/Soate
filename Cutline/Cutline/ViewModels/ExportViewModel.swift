import Observation
import UIKit

/// Drives the export sheet: settings, size estimate, progress, cancel,
/// background time, saving to Photos and sharing.
@MainActor
@Observable
final class ExportViewModel {
    enum Phase: Equatable {
        case settings
        case exporting(Double)
        case finished(URL)
        case failed(String)
    }

    var settings = ExportSettings()
    private(set) var phase: Phase = .settings
    private(set) var savedToPhotos = false
    var shareURL: URL?
    var message: String?

    private let project: Project
    @ObservationIgnored private let service = ExportService()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(project: Project) {
        self.project = project
    }

    var duration: Double { project.duration }

    var estimatedSize: String {
        let bytes = settings.estimatedBytes(duration: project.duration, aspect: project.canvas.aspect)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var renderSizeText: String {
        let size = settings.renderSize(for: project.canvas.aspect)
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    func start() {
        guard task == nil else { return }
        phase = .exporting(0)
        savedToPhotos = false
        beginBackgroundTime()
        let project = self.project
        let settings = self.settings
        let service = self.service
        task = Task { [weak self] in
            do {
                let url = try await service.exportVideo(project: project, settings: settings) { value in
                    Task { @MainActor in
                        guard let self, case .exporting = self.phase else { return }
                        self.phase = .exporting(value)
                    }
                }
                self?.phase = .finished(url)
                Haptics.success()
            } catch ExportError.cancelled {
                self?.phase = .settings
            } catch {
                self?.phase = .failed(error.localizedDescription)
                Haptics.warning()
            }
            self?.task = nil
            self?.endBackgroundTime()
        }
    }

    func cancel() {
        service.cancel()
        task?.cancel()
    }

    func reset() {
        phase = .settings
    }

    func saveToPhotos() {
        guard case .finished(let url) = phase else { return }
        Task {
            do {
                try await ExportService.saveVideoToPhotos(url)
                savedToPhotos = true
                Haptics.success()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func share() {
        guard case .finished(let url) = phase else { return }
        shareURL = url
    }

    func exportAudioOnly() {
        let project = self.project
        message = "Exporting audio…"
        Task {
            do {
                shareURL = try await ExportService.exportAudio(project: project)
                message = nil
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func saveStillFrame(at time: Double) {
        let project = self.project
        let shortSide = settings.resolution.shortSide
        message = "Saving frame…"
        Task {
            do {
                let image = try await ExportService.stillFrame(project: project, at: time, shortSide: shortSide)
                try await ExportService.saveImageToPhotos(image)
                message = "Frame saved to Photos."
                Haptics.success()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func beginBackgroundTime() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Cutline Export") { [weak self] in
            MainActor.assumeIsolated {
                self?.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
