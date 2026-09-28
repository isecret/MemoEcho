import AVFoundation
import Foundation

/// Measures live input only; no audio is retained or sent to a provider.
@MainActor
@Observable
final class MicrophoneLevelController {
    private(set) var isRunning = false
    private(set) var level: Float = 0
    private(set) var message: String?
    private let recorder: any AudioRecording
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(recorder: any AudioRecording = AudioRecorder(retainsAudio: false)) {
        self.recorder = recorder
    }

    func start(device: AVCaptureDevice?, authorize: () throws -> Void) {
        guard !isRunning else { return }
        stop()
        do { try authorize() }
        catch { message = "请先开启麦克风权限"; return }
        let id = generation
        isRunning = true
        recorder.onCaptureEvent = { [weak self] event in
            guard let self, self.generation == id, self.isRunning else { return }
            if case .interrupted = event {
                self.stop()
                self.message = "麦克风不可用，请检查设备"
            }
        }
        task = Task { [weak self] in
            guard let self, self.generation == id, !Task.isCancelled else { return }
            do {
                try await self.recorder.startRecording(device: device, onPCMChunk: nil)
                guard self.generation == id, !Task.isCancelled else { return }
                while !Task.isCancelled, self.generation == id {
                    self.level = self.recorder.currentLevel()
                    try await Task.sleep(for: .milliseconds(80))
                }
            } catch {
                guard self.generation == id else { return }
                self.stop()
                self.message = "麦克风不可用，请检查设备"
            }
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        recorder.onCaptureEvent = nil
        if isRunning { _ = recorder.stopRecording() }
        isRunning = false
        level = 0
        message = nil
    }
}
