import SwiftUI
import AVFoundation
import CryptoKit

struct RecordingSaveState: Codable, Sendable {
    var assetUrl: String?
    let name: String
    var noteUrl: String
    let accountUrl: String?
    var embedded: Bool
}

struct RecordingSaveResult: Sendable {
    let state: RecordingSaveState?
    let succeeded: Bool
}

private struct RecordingRecovery: Codable {
    let state: RecordingSaveState?
    let completed: Bool?

    init(state: RecordingSaveState?, completed: Bool = false) {
        self.state = state
        self.completed = completed
    }
}

@MainActor @Observable
final class AudioRecorder {
    var isRecording = false
    var elapsed: TimeInterval = 0
    var level: Float = 0
    var permissionDenied = false
    var saveFailed = false
    var saveError: String?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private(set) var saveState: RecordingSaveState?
    @ObservationIgnored private var recoveryKey: String?
    @ObservationIgnored private var requestedRecoveryKey: String?
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var generation = 0

    func configureRecovery(_ key: String) {
        requestedRecoveryKey = key
        guard recoveryKey != key, !isStarting, !isRecording, fileURL == nil else { return }
        recoveryKey = key
        saveState = nil
        saveFailed = false
        saveError = nil
        guard let urls = recoveryURLs() else { return }
        let recovery: RecordingRecovery? = {
            guard let values = try? urls.state.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize,
                  size <= 1_048_576,
                  let data = try? Data(contentsOf: urls.state, options: .mappedIfSafe)
            else { return nil }
            return try? JSONDecoder().decode(RecordingRecovery.self, from: data)
        }()
        if recovery?.completed == true {
            do {
                try FileManager.default.removeItem(at: urls.audio)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            } catch {
                return
            }
            try? FileManager.default.removeItem(at: urls.state)
            return
        }
        guard FileManager.default.fileExists(atPath: urls.audio.path) else {
            try? FileManager.default.removeItem(at: urls.state)
            return
        }
        fileURL = urls.audio
        saveState = recovery?.state
        saveFailed = true
        saveError = "A recording is waiting to be saved."
    }

    func start() async {
        guard !isStarting, !isRecording, fileURL == nil else { return }
        isStarting = true
        defer {
            isStarting = false
            if fileURL == nil,
               let requestedRecoveryKey,
               requestedRecoveryKey != recoveryKey {
                configureRecovery(requestedRecoveryKey)
            }
        }
        saveFailed = false
        saveError = nil
        let gen = generation
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            permissionDenied = true
            return
        }
        permissionDenied = false
        guard !isRecording, gen == generation, !Task.isCancelled else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let url = recoveryURLs()?.audio ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            try? FileManager.default.removeItem(at: url)
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            return
        }
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            try? FileManager.default.removeItem(at: url)
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            return
        }
        self.recorder = recorder
        fileURL = url
        elapsed = 0
        isRecording = true
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let recorder = self.recorder else { return }
                if !recorder.isRecording {
                    self.finishRecorder()
                    self.saveFailed = true
                    self.saveError = "Recording stopped. Select Done to save it."
                    self.persistRecovery()
                    return
                }
                recorder.updateMeters()
                self.elapsed = recorder.currentTime
                // -60dB..0dB -> 0..1
                self.level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 60) / 60))
            }
        }
    }

    deinit {
        ticker?.cancel()
        recorder?.stop()
    }

    func cancel() {
        finishRecorder()
        saveFailed = false
        saveError = nil
        saveState = nil
        let stateURL = recoveryURLs()?.state
        guard let fileURL else {
            if let stateURL { try? FileManager.default.removeItem(at: stateURL) }
            if let requestedRecoveryKey, requestedRecoveryKey != recoveryKey {
                configureRecovery(requestedRecoveryKey)
            }
            return
        }
        var removed = false
        do {
            try FileManager.default.removeItem(at: fileURL)
            removed = true
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            removed = true
        } catch {
        }
        if removed {
            if let stateURL { try? FileManager.default.removeItem(at: stateURL) }
        } else {
            _ = persistRecovery(completed: true)
        }
        self.fileURL = nil
        if let requestedRecoveryKey, requestedRecoveryKey != recoveryKey {
            configureRecovery(requestedRecoveryKey)
        }
    }

    func stop() async -> Data? {
        finishRecorder()
        guard let fileURL else {
            saveFailed = true
            saveError = "Couldn't read this recording."
            return nil
        }
        let data = await Task.detached {
            try? Data(contentsOf: fileURL, options: .mappedIfSafe)
        }.value
        saveFailed = true
        saveError = data == nil ? "Couldn't read this recording." : nil
        persistRecovery()
        return data
    }

    func retainSaveState(_ state: RecordingSaveState?) {
        saveState = state
        saveFailed = true
        saveError = "Couldn't save this recording. It is still available to retry."
        persistRecovery()
    }

    @discardableResult
    func captureSaveState(_ state: RecordingSaveState) -> Bool {
        let previous = saveState
        saveState = state
        guard persistRecovery() else {
            saveState = previous
            saveError = "Couldn't preserve this recording yet."
            return false
        }
        return true
    }

    func completeSave(_ state: RecordingSaveState? = nil) {
        if let state { saveState = state }
        saveFailed = false
        saveError = nil
        defer {
            saveState = nil
            fileURL = nil
            if let requestedRecoveryKey, requestedRecoveryKey != recoveryKey {
                configureRecovery(requestedRecoveryKey)
            }
        }
        guard let fileURL else { return }
        guard let urls = recoveryURLs() else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        _ = persistRecovery(completed: true)
        do {
            try FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: urls.state)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            try? FileManager.default.removeItem(at: urls.state)
        } catch {
        }
    }

    private func recoveryURLs() -> (audio: URL, state: URL)? {
        guard let recoveryKey, let root = LushShared.container else { return nil }
        let directory = root.appendingPathComponent("RecordingRecovery", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(recoveryKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return (
            directory.appendingPathComponent("\(name).m4a"),
            directory.appendingPathComponent("\(name).json")
        )
    }

    @discardableResult
    private func persistRecovery(completed: Bool = false) -> Bool {
        guard let urls = recoveryURLs(),
              let data = try? JSONEncoder().encode(
                  RecordingRecovery(state: saveState, completed: completed)
              ) else { return false }
        do {
            try data.write(to: urls.state, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func finishRecorder() {
        generation += 1
        ticker?.cancel()
        ticker = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        level = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// Apple Notes-style recording bar: red dot, level, elapsed time, Done.
struct RecorderBar: View {
    let recorder: AudioRecorder
    let recoveryKey: String
    let prepareSave: () -> RecordingSaveState
    let onSave: (Data, RecordingSaveState?) async -> RecordingSaveResult
    let onSaved: () -> Void
    let onCancel: () -> Void
    @State private var isStopping = false

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
            if let saveError = recorder.saveError {
                Text(saveError)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel) {
                recorder.cancel()
                onCancel()
            }
            .disabled(isStopping)
            Button("Done") {
                guard !isStopping else { return }
                guard recorder.saveState != nil || recorder.captureSaveState(prepareSave()) else { return }
                isStopping = true
                Task {
                    guard let data = await recorder.stop() else {
                        isStopping = false
                        return
                    }
                    let result = await onSave(data, recorder.saveState)
                    if result.succeeded {
                        recorder.completeSave(result.state)
                        onSaved()
                    } else {
                        recorder.retainSaveState(result.state)
                        isStopping = false
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isStopping || (!recorder.isRecording && !recorder.saveFailed))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .task(id: recoveryKey) {
            recorder.configureRecovery(recoveryKey)
            if !recorder.saveFailed {
                let state = prepareSave()
                guard recorder.saveState != nil || recorder.captureSaveState(state) else { return }
                await recorder.start()
            }
        }
        .onDisappear {
            if isStopping {
                return
            }
            if recorder.isRecording {
                if recorder.saveState == nil {
                    _ = recorder.captureSaveState(prepareSave())
                }
                Task { _ = await recorder.stop() }
            } else if !recorder.saveFailed {
                recorder.cancel()
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let seconds = Int(t)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
