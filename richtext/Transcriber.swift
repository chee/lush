import Foundation
import Speech
import AVFoundation

/// On-device speech-to-text for audio attachments, stored on the asset doc
/// so recordings show up in search.
enum Transcriber {
    static func transcribe(_ data: Data, fileExtension: String) async -> String? {
        guard SpeechTranscriber.isAvailable else { return nil }
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        let locale = supported.first {
            $0.identifier(.bcp47) == current.identifier(.bcp47)
        } ?? supported.first {
            $0.language.languageCode == current.language.languageCode
        } ?? supported.first
        guard let locale else { return nil }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-\(UUID().uuidString).\(fileExtension)")
        do {
            try data.write(to: tempURL)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await request.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let file = try AVAudioFile(forReading: tempURL)
            async let collected = transcriber.results.reduce(into: "") { text, result in
                text += String(result.text.characters)
            }
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let transcript = try await collected
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return transcript.isEmpty ? nil : transcript
        } catch {
            return nil
        }
    }
}
