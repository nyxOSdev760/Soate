import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ImportError: LocalizedError {
    case unsupportedFormat(String)
    case unreadable(String)
    case lowStorage
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name):
            return "\(name) isn't a supported video, photo or audio format."
        case .unreadable(let name):
            return "\(name) couldn't be read. It may be damaged or still downloading from iCloud."
        case .lowStorage:
            return StoreError.lowStorage.errorDescription
        case .permissionDenied:
            return "Cutline doesn't have permission to read that file."
        }
    }
}

/// A movie handed over by the photo picker as a file.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// Copies picked media into the project, reads its properties and creates
/// low-resolution proxies for large videos so editing stays smooth.
final class MediaImportService: @unchecked Sendable {
    static let shared = MediaImportService()

    /// Videos larger than this on their long side get a 720p proxy.
    static let proxyThreshold: Double = 1920

    private let store = ProjectStore.shared

    struct BatchResult {
        var assets: [MediaAsset] = []
        var failures: [String] = []
    }

    func importPickerItems(_ items: [PhotosPickerItem], projectID: UUID) async -> BatchResult {
        var result = BatchResult()
        for (index, item) in items.enumerated() {
            let label = "Item \(index + 1)"
            do {
                let isMovie = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
                if isMovie {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                        throw ImportError.unreadable(label)
                    }
                    let asset = try await importFile(at: movie.url, projectID: projectID, displayName: label, moveFile: true)
                    result.assets.append(asset)
                } else {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw ImportError.unreadable(label)
                    }
                    guard let image = UIImage(data: data) else { throw ImportError.unsupportedFormat(label) }
                    result.assets.append(try importImage(image, projectID: projectID, displayName: "Photo"))
                }
            } catch {
                result.failures.append(error.localizedDescription)
            }
        }
        return result
    }

    /// Imports a file from Files (security-scoped) or a temporary location.
    func importFile(at url: URL, projectID: UUID, displayName: String? = nil, moveFile: Bool = false) async throws -> MediaAsset {
        let name = displayName ?? url.deletingPathExtension().lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        do {
            try store.ensureSpace(bytes: size)
        } catch {
            throw ImportError.lowStorage
        }
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let fileName = "\(UUID().uuidString).\(ext)"
        let destination = store.mediaURL(projectID: projectID, fileName: fileName)
        do {
            if moveFile {
                try FileManager.default.moveItem(at: url, to: destination)
            } else {
                try FileManager.default.copyItem(at: url, to: destination)
            }
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw ImportError.lowStorage
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw ImportError.permissionDenied
        } catch {
            throw ImportError.unreadable(name)
        }
        do {
            var asset = try await analyze(url: destination, fileName: fileName, displayName: name)
            if asset.kind == .video, max(asset.width, asset.height) > MediaImportService.proxyThreshold {
                if let proxy = await makeProxy(for: destination, projectID: projectID) {
                    asset.proxyFileName = proxy.fileName
                    asset.proxyOrientation = proxy.orientation
                }
            }
            return asset
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func importImage(_ image: UIImage, projectID: UUID, displayName: String) throws -> MediaAsset {
        let normalized = MediaImportService.normalized(image, maxDimension: 3840)
        guard let data = normalized.jpegData(compressionQuality: 0.9) else { throw ImportError.unsupportedFormat(displayName) }
        do {
            try store.ensureSpace(bytes: Int64(data.count))
        } catch {
            throw ImportError.lowStorage
        }
        let fileName = "\(UUID().uuidString).jpg"
        try data.write(to: store.mediaURL(projectID: projectID, fileName: fileName), options: .atomic)
        return MediaAsset(kind: .image, fileName: fileName, displayName: displayName, duration: 3,
                          width: Double(normalized.size.width), height: Double(normalized.size.height),
                          hasAudio: false, hasVideo: false)
    }

    /// Registers a file that is already in the media folder (voiceover,
    /// reversed clips, cleaned audio).
    func registerGeneratedFile(fileName: String, projectID: UUID, displayName: String) async throws -> MediaAsset {
        try await analyze(url: store.mediaURL(projectID: projectID, fileName: fileName), fileName: fileName, displayName: displayName)
    }

    func analyze(url: URL, fileName: String, displayName: String) async throws -> MediaAsset {
        let asset = AVURLAsset(url: url)
        let isPlayable: Bool
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            (isPlayable, duration) = try await asset.load(.isPlayable, .duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ImportError.unreadable(displayName)
        }
        guard isPlayable, duration.seconds.isFinite, duration.seconds > 0 else {
            throw ImportError.unsupportedFormat(displayName)
        }
        if let video = videoTracks.first {
            let (naturalSize, transform) = try await video.load(.naturalSize, .preferredTransform)
            let degrees = MediaImportService.degrees(of: transform)
            let rotated = degrees % 180 != 0
            return MediaAsset(kind: .video, fileName: fileName, displayName: displayName, duration: duration.seconds,
                              width: Double(rotated ? naturalSize.height : naturalSize.width),
                              height: Double(rotated ? naturalSize.width : naturalSize.height),
                              orientation: degrees, hasAudio: !audioTracks.isEmpty, hasVideo: true)
        }
        guard !audioTracks.isEmpty else { throw ImportError.unsupportedFormat(displayName) }
        return MediaAsset(kind: .audio, fileName: fileName, displayName: displayName, duration: duration.seconds,
                          width: 0, height: 0, hasAudio: true, hasVideo: false)
    }

    private func makeProxy(for url: URL, projectID: UUID) async -> (fileName: String, orientation: Int)? {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
        let fileName = "\(UUID().uuidString)-proxy.mp4"
        let output = store.mediaURL(projectID: projectID, fileName: fileName)
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        let proxyAsset = AVURLAsset(url: output)
        guard let track = try? await proxyAsset.loadTracks(withMediaType: .video).first,
              let transform = try? await track.load(.preferredTransform) else {
            return (fileName, 0)
        }
        return (fileName, MediaImportService.degrees(of: transform))
    }

    static func degrees(of transform: CGAffineTransform) -> Int {
        let angle = atan2(Double(transform.b), Double(transform.a)) * 180 / Double.pi
        let rounded = Int((angle / 90).rounded()) * 90
        return (rounded + 360) % 360
    }

    static func normalized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let factor = min(1, maxDimension / max(pixelWidth, pixelHeight, 1))
        let target = CGSize(width: max(1, floor(pixelWidth * factor)), height: max(1, floor(pixelHeight * factor)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
