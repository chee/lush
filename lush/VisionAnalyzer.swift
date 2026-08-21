import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Extracts OCR text and a label-based description from an image, for the
/// `@computervision` metadata on UnixFileEntry docs.
enum VisionAnalyzer {
    /// The long edge of what the requests are handed, rather than the photo
    /// itself. A 12-megapixel original is ~48MB of bitmap, and this runs right
    /// after an insert, while the note's own doc is being written.
    ///
    /// Text recognition sets the floor — classification resizes to a couple of
    /// hundred pixels on its own, so it never wanted the original. A page
    /// photographed at arm's length still has legible glyphs at this size, and
    /// it is a quarter of the pixels.
    static let maxPixelSize = 2048

    static func analyze(_ imageData: Data) async -> (description: String, ocr: String)? {
        guard let image = bounded(imageData) else { return nil }
        let ocr = await recognizeText(image)
        let description = await classify(image)
        if ocr.isEmpty, description.isEmpty {
            return nil
        }
        return (description, ocr)
    }

    /// ImageIO subsamples as it decodes, so the full-size bitmap is never
    /// built — the same trick the editor draws pictures with. The transform
    /// bakes the EXIF orientation in, which is what lets the requests take the
    /// image without being told which way up it is. An image already under the
    /// cap comes back at its own size.
    static func bounded(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func recognizeText(_ image: CGImage) async -> String {
        var request = RecognizeTextRequest()
        request.automaticallyDetectsLanguage = true
        guard let observations = try? await request.perform(on: image) else {
            return ""
        }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private static func classify(_ image: CGImage) async -> String {
        let request = ClassifyImageRequest()
        guard let observations = try? await request.perform(on: image) else {
            return ""
        }
        return observations
            .filter { $0.confidence > 0.3 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(6)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            .joined(separator: ", ")
    }
}
