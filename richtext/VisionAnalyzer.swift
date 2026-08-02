import Foundation
import Vision

/// Extracts OCR text and a label-based description from an image, for the
/// `@computervision` metadata on UnixFileEntry docs.
enum VisionAnalyzer {
    static func analyze(_ imageData: Data) async -> (description: String, ocr: String)? {
        let ocr = await recognizeText(imageData)
        let description = await classify(imageData)
        if ocr.isEmpty, description.isEmpty {
            return nil
        }
        return (description, ocr)
    }

    private static func recognizeText(_ data: Data) async -> String {
        var request = RecognizeTextRequest()
        request.automaticallyDetectsLanguage = true
        guard let observations = try? await request.perform(on: data) else {
            return ""
        }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private static func classify(_ data: Data) async -> String {
        let request = ClassifyImageRequest()
        guard let observations = try? await request.perform(on: data) else {
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
