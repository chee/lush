import SwiftUI
import AVFoundation

@MainActor @Observable
final class AudioRecorder {
    var isRecording = false
    var elapsed: TimeInterval = 0
    var level: Float = 0
    var permissionDenied = false

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var generation = 0

    func start() async {
        guard !isRecording else { return }
        let gen = generation
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            permissionDenied = true
            return
        }
        guard !isRecording, gen == generation, !Task.isCancelled else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            return
        }
        recorder.isMeteringEnabled = true
        recorder.record()
        self.recorder = recorder
        fileURL = url
        elapsed = 0
        isRecording = true
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.elapsed = recorder.currentTime
                // -60dB..0dB -> 0..1
                self.level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 60) / 60))
            }
        }
    }

    deinit {
        ticker?.cancel()
    }

    func cancel() {
        finishRecorder()
        cleanupFile()
    }

    func stop() -> Data? {
        finishRecorder()
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            cleanupFile()
            return nil
        }
        cleanupFile()
        return data
    }

    private func finishRecorder() {
        generation += 1
        ticker?.cancel()
        ticker = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
    }

    private func cleanupFile() {
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
    }
}

/// Apple Notes-style recording bar: red dot, level, elapsed time, Done.
struct RecorderBar: View {
    let recorder: AudioRecorder
    let onFinish: (Data?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(recorder.isRecording ? 1 : 0.3)
                .scaleEffect(1 + CGFloat(recorder.level) * 0.5)
                .animation(.easeOut(duration: 0.1), value: recorder.level)
            Text(timeString(recorder.elapsed))
                .font(.body.monospacedDigit())
            Capsule()
                .fill(.red.opacity(0.35 + Double(recorder.level) * 0.65))
                .frame(width: 60 + CGFloat(recorder.level) * 80, height: 4)
                .animation(.easeOut(duration: 0.1), value: recorder.level)
            Spacer()
            if recorder.permissionDenied {
                Text("Microphone access denied")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel) {
                recorder.cancel()
                onFinish(nil)
            }
            Button("Done") {
                onFinish(recorder.stop())
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .task {
            await recorder.start()
        }
        .onDisappear {
            recorder.cancel()
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let seconds = Int(t)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
