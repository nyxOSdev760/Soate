import UIKit

enum ImageStoreError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        "The image couldn't be compressed for saving."
    }
}

/// Stores imported images as separate files referenced by ID, with an
/// in-memory cache of decoded images.
final class ImageStore: @unchecked Sendable {
    static let shared = ImageStore()

    /// Imported images are downscaled so their longest side is at most this.
    static let maxPixelDimension: CGFloat = 2048
    static let jpegQuality: CGFloat = 0.8

    struct ImportedImage {
        let id: String
        let pixelSize: CGSize
    }

    private let cache = NSCache<NSString, UIImage>()
    private let store: BoardStore

    init(store: BoardStore = .shared) {
        self.store = store
        cache.countLimit = 150
        cache.totalCostLimit = 300 * 1024 * 1024
    }

    func url(for id: String) -> URL {
        store.imagesURL.appendingPathComponent(id)
    }

    func image(for id: String) -> UIImage? {
        let key = id as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let loaded = UIImage(contentsOfFile: url(for: id).path) else { return nil }
        let prepared = loaded.preparingForDisplay() ?? loaded
        cache.setObject(prepared, forKey: key, cost: ImageStore.cost(of: prepared))
        return prepared
    }

    /// Downscales, compresses and writes an image. Returns its new ID.
    func importImage(_ image: UIImage) throws -> ImportedImage {
        let hasAlpha = ImageStore.hasAlpha(image)
        let normalized = ImageStore.downscaled(image, maxDimension: ImageStore.maxPixelDimension, opaque: !hasAlpha)
        let data: Data?
        let fileExtension: String
        if hasAlpha {
            data = normalized.pngData()
            fileExtension = "png"
        } else {
            data = normalized.jpegData(compressionQuality: ImageStore.jpegQuality)
            fileExtension = "jpg"
        }
        guard let data else { throw ImageStoreError.encodingFailed }
        try store.ensureSpace(for: Int64(data.count))
        store.prepareDirectories()
        let id = "\(UUID().uuidString).\(fileExtension)"
        do {
            try data.write(to: url(for: id), options: .atomic)
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw StorageError.lowStorage
        }
        cache.setObject(normalized, forKey: id as NSString, cost: ImageStore.cost(of: normalized))
        return ImportedImage(id: id, pixelSize: normalized.size)
    }

    func removeImages(notIn referenced: Set<String>, olderThan cutoff: Date) {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        let files = (try? fileManager.contentsOfDirectory(at: store.imagesURL, includingPropertiesForKeys: keys)) ?? []
        for file in files where !referenced.contains(file.lastPathComponent) {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let date = values?.contentModificationDate ?? values?.creationDate ?? Date()
            if date < cutoff {
                try? fileManager.removeItem(at: file)
                cache.removeObject(forKey: file.lastPathComponent as NSString)
            }
        }
    }

    // MARK: Helpers

    static func hasAlpha(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        switch cgImage.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            return true
        default:
            return false
        }
    }

    /// Redraws the image at scale 1 (this also bakes in EXIF orientation).
    static func downscaled(_ image: UIImage, maxDimension: CGFloat, opaque: Bool) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else { return image }
        let factor = min(1, maxDimension / max(pixelWidth, pixelHeight))
        let target = CGSize(width: max(1, floor(pixelWidth * factor)), height: max(1, floor(pixelHeight * factor)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }
}
