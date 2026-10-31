import UIKit

enum ExportFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg
    case pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .pdf: return "PDF"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .pdf: return "pdf"
        }
    }

    var systemImage: String {
        switch self {
        case .png, .jpeg: return "photo"
        case .pdf: return "doc.richtext"
        }
    }
}

enum ExportError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        "The export couldn't be created."
    }
}

/// Renders boards or selections to PNG, JPEG or PDF files, and renders
/// home screen thumbnails.
final class ExportService {
    static let maxImagePixels: CGFloat = 4096
    static let maxPDFPoints: CGFloat = 14_400
    static let padding: CGFloat = 48

    private let renderer: CanvasRenderer

    init(imageStore: ImageStore = .shared) {
        renderer = CanvasRenderer(imageStore: imageStore)
    }

    func export(objects: [BoardObject],
                board: Board,
                format: ExportFormat,
                fallbackRect: CGRect,
                nameSuffix: String = "") throws -> URL {
        let theme = ThemeManager.shared.theme(for: board.themeID)
        var bounds = objects.reduce(CGRect.null) { $0.union($1.boundingBox) }
        if bounds.isNull || bounds.width < 1 || bounds.height < 1 {
            bounds = fallbackRect
        }
        bounds = bounds.insetBy(dx: -ExportService.padding, dy: -ExportService.padding).integral
        let longestSide = max(bounds.width, bounds.height, 1)

        let data: Data
        switch format {
        case .png, .jpeg:
            let pixelScale = max(0.05, min(2, ExportService.maxImagePixels / longestSide))
            let rendererFormat = UIGraphicsImageRendererFormat()
            rendererFormat.scale = pixelScale
            rendererFormat.opaque = true
            let image = UIGraphicsImageRenderer(size: bounds.size, format: rendererFormat).image { context in
                self.render(objects: objects, board: board, theme: theme, bounds: bounds, ctx: context.cgContext)
            }
            let encoded = format == .png ? image.pngData() : image.jpegData(compressionQuality: 0.9)
            guard let encoded else { throw ExportError.encodingFailed }
            data = encoded
        case .pdf:
            let pdfScale = min(1, ExportService.maxPDFPoints / longestSide)
            let pageRect = CGRect(x: 0, y: 0, width: bounds.width * pdfScale, height: bounds.height * pdfScale)
            let pdfRenderer = UIGraphicsPDFRenderer(bounds: pageRect)
            data = pdfRenderer.pdfData { context in
                context.beginPage()
                context.cgContext.scaleBy(x: pdfScale, y: pdfScale)
                self.render(objects: objects, board: board, theme: theme, bounds: bounds, ctx: context.cgContext)
            }
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = ExportService.sanitizedFileName(board.name + nameSuffix) + "." + format.fileExtension
        let url = directory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func render(objects: [BoardObject], board: Board, theme: Theme, bounds: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        renderer.drawBackground(in: ctx, worldRect: bounds, theme: theme, pattern: board.pattern, scale: 1)
        renderer.drawObjects(objects, in: ctx, theme: theme, visibleRect: nil)
        ctx.restoreGState()
    }

    /// A 4:3 JPEG preview of the board's content.
    func thumbnailData(for board: Board) -> Data? {
        let theme = ThemeManager.shared.theme(for: board.themeID)
        let size = CGSize(width: 400, height: 300)
        var content = board.objects.reduce(CGRect.null) { $0.union($1.boundingBox) }
        if content.isNull || content.width < 1 || content.height < 1 {
            content = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        }
        content = content.insetBy(dx: -32, dy: -32)
        let scale = min(size.width / content.width, size.height / content.height, 1.5)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let ctx = context.cgContext
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -content.midX, y: -content.midY)
            let world = CGRect(center: content.center, size: CGSize(width: size.width / scale, height: size.height / scale))
            self.renderer.drawBackground(in: ctx, worldRect: world, theme: theme, pattern: board.pattern, scale: scale)
            self.renderer.drawObjects(board.objects, in: ctx, theme: theme, visibleRect: world)
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    static func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Slate Board" : cleaned
    }
}
