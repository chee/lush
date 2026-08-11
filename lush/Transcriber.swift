import Foundation
import Speech
import AVFoundation

/// On-device speech-to-text for audio attachments, stored on the asset doc
/// so recordings show up in search.
enum Transcriber {
    static func locale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        return supported.first {
            $0.identifier(.bcp47) == current.identifier(.bcp47)
        } ?? supported.first {
            $0.language.languageCode == current.language.languageCode
        } ?? supported.first
    }

    static func transcribe(_ data: Data, fileExtension: String) async -> String? {
        guard SpeechTranscriber.isAvailable else { return nil }
        guard let locale = await locale() else { return nil }

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

@MainActor
final class LiveTranscriber {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var stopped = false

    /// `onInterim` carries the volatile text for the utterance in progress and
    /// is superseded by the next call; `onFinal` carries one finalized segment
    /// and is never revised. Neither accumulates — the caller owns the
    /// transcript so it can commit finalized text once and rewrite only the
    /// volatile tail.
    func start(
        onInterim: @escaping @MainActor (String) -> Void,
        onFinal: @escaping @MainActor (String) -> Void
    ) async -> Bool {
        guard SpeechTranscriber.isAvailable,
              await AVAudioApplication.requestRecordPermission(),
              !stopped,
              let locale = await Transcriber.locale()
        else { return false }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await request.downloadAndInstall()
            }
            guard !stopped else { return false }

            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif

            let engine = AVAudioEngine()
            let node = engine.inputNode
            let inputFormat = node.outputFormat(forBus: 0)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber],
                considering: inputFormat
            ) else { return false }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.prepareToAnalyze(in: format)
            let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
            let converter = AVAudioConverter(from: inputFormat, to: format)
            node.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                guard let copy = Self.convert(buffer, to: format, with: converter) else { return }
                input.yield(AnalyzerInput(buffer: copy))
            }
            engine.prepare()
            try engine.start()

            self.engine = engine
            self.analyzer = analyzer
            self.input = input
            resultsTask = Task {
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        if result.isFinal {
                            onFinal(text)
                        } else {
                            onInterim(text)
                        }
                    }
                } catch {}
            }
            analysisTask = Task {
                try? await analyzer.start(inputSequence: stream)
            }
            return true
        } catch {
            return false
        }
    }

    func stop() async {
        stopped = true
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        input?.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        analysisTask?.cancel()
        analysisTask = nil
        resultsTask = nil
        input = nil
        analyzer = nil
        engine = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat,
        with converter: AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        guard let converter else { return copy(buffer) }
        let capacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)
        ) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            guard !supplied else {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : output
    }

    private nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData
            else { continue }
            memcpy(destinationData, sourceData, Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return copy
    }
}
