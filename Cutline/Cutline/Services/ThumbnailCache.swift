import AVFoundation
import UIKit

/// Generates and caches small video frames for the timeline. Requests run
/// off the main thread and identical requests are served from memory.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private var generators: [URL: AVAssetImageGenerator] = [:]

    init() {
        cache.countLimit = 600
    }

    func thumbnail(url: URL, time: Double, height: CGFloat = 96) async -> UIImage? {
        let bucket = (time * 4).rounded() / 4
        let key = "\(url.lastPathComponent)|\(bucket)|\(Int(height))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let generator = generator(for: url, height: height)
        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: bucket, preferredTimescale: 600))
            let image = UIImage(cgImage: cgImage)
            cache.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }

    func image(url: URL) -> UIImage? {
        let key = "image|\(url.lastPathComponent)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let small = MediaImportService.normalized(image, maxDimension: 200)
        cache.setObject(small, forKey: key)
        return small
    }

    private func generator(for url: URL, height: CGFloat) -> AVAssetImageGenerator {
        if let existing = generators[url] {
            return existing
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 2, height: height * 2)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        if generators.count > 40 {
            generators.removeAll()
        }
        generators[url] = generator
        return generator
    }
}
