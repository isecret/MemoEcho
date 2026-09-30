import AVFoundation
import Foundation

protocol AudioRecording: AnyObject {
    @MainActor var onCaptureEvent: (@MainActor @Sendable (AudioCaptureEvent) -> Void)? { get set }
    @MainActor var currentDurationMs: Int { get }
    @MainActor func startRecording(device: AVCaptureDevice?, onPCMChunk: (@Sendable (Data) -> Void)?) async throws
    @MainActor func startRecording(device: AVCaptureDevice?, retainFullAudio: Bool, onPCMChunk: (@Sendable (Data) -> Void)?) async throws
    @MainActor func currentLevel() -> Float
    @MainActor func stopRecording() -> AudioRecordingResult
}

extension AudioRecording {
    /// Existing recorder doubles retain their previous behavior. AudioRecorder
    /// implements this requirement to disable its full-recording PCM copy.
    @MainActor
    func startRecording(device: AVCaptureDevice?, retainFullAudio: Bool,
                        onPCMChunk: (@Sendable (Data) -> Void)?) async throws {
        try await startRecording(device: device, onPCMChunk: onPCMChunk)
    }
}

/// 音频录制器，直接采集为 PCM/WAV 16kHz mono，并支持指定输入设备
final class AudioRecorder: NSObject, AudioRecording, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    static let sampleRate: Double = 16_000
    static let channels: Int = 1

    /// 低于此阈值的录音视为误触，静默取消
    static let shortRecordingThreshold: TimeInterval = 0.5

    /// PCM chunk 实时回调，用于分段器接收音频数据（通过 callbackLock 保护跨队列访问）
    private let callbackLock = NSLock()
    private var _onPCMChunk: (@Sendable (Data) -> Void)?

    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let captureQueue = DispatchQueue(label: "memoecho.audio.capture")
    private let sampleLock = NSLock()
    private let retainsAudio: Bool
    private var retainFullAudio = true
    private var capturedSampleCount = 0
    private var capturedPCMData = Data()
    private var latestLevel: Float = 0
    private var recording = false
    @MainActor var onCaptureEvent: (@MainActor @Sendable (AudioCaptureEvent) -> Void)?
    @MainActor private var captureID = UUID()
    @MainActor private var observers: [NSObjectProtocol] = []
    @MainActor private var healthTask: Task<Void, Never>?
    private var lastBufferAt: TimeInterval?
    private var intervalPeakRMS: Float = 0
    private var acceptingOutput: AVCaptureOutput?

    /// Level monitoring discards each PCM chunk after measuring it.
    init(retainsAudio: Bool = true) {
        self.retainsAudio = retainsAudio
        super.init()
    }

    @MainActor
    var currentDurationMs: Int {
        guard recording else { return 0 }
        return sampleLock.withLock { capturedSampleCount * 1_000 / Int(Self.sampleRate) }
    }

    /// 开始录音（MainActor 调用）
    ///
    /// - Parameters:
    ///   - device: 录音设备，为 nil 时使用系统默认
    ///   - onPCMChunk: PCM 数据实时回调，在 cleanup 后、startRunning 前设置，避免被清理
    @MainActor
    func startRecording(device: AVCaptureDevice?, onPCMChunk: (@Sendable (Data) -> Void)? = nil) async throws {
        try await startRecording(device: device, retainFullAudio: true, onPCMChunk: onPCMChunk)
    }

    /// Real-time ASR consumes callbacks and opts out of a full-recording PCM copy.
    @MainActor
    func startRecording(device: AVCaptureDevice?, retainFullAudio: Bool,
                        onPCMChunk: (@Sendable (Data) -> Void)? = nil) async throws {
        guard !recording else { return }

        cleanupRecordingState()
        sampleLock.withLock { self.retainFullAudio = retainFullAudio && retainsAudio }
        let id = captureID
        callbackLock.withLock { _onPCMChunk = onPCMChunk }

        let captureDevice: AVCaptureDevice?
        if let device {
            captureDevice = device
        } else {
            captureDevice = AVCaptureDevice.default(for: .audio)
        }

        guard let captureDevice else {
            throw AudioRecorderError.noInputDevice
        }

        let session = AVCaptureSession()

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        do {
            let input = try AVCaptureDeviceInput(device: captureDevice)
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = settings
            output.setSampleBufferDelegate(self, queue: captureQueue)

            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw AudioRecorderError.deviceUnavailable(captureDevice.localizedName)
            }
            session.addInput(input)

            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw AudioRecorderError.startFailed
            }
            session.addOutput(output)
            session.commitConfiguration()

            sampleLock.withLock {
                capturedPCMData.removeAll(keepingCapacity: false)
                capturedSampleCount = 0
                latestLevel = 0
            }

            captureSession = session
            audioOutput = output
            sampleLock.withLock { acceptingOutput = output }
            observeCapture(session: session, device: captureDevice, id: id)

            let didStart = await withCheckedContinuation { continuation in
                captureQueue.async {
                    session.startRunning()
                    continuation.resume(returning: session.isRunning)
                }
            }

            guard id == captureID else { throw CancellationError() }
            try Task.checkCancellation()
            guard didStart else {
                output.setSampleBufferDelegate(nil, queue: nil)
                captureSession = nil
                audioOutput = nil
                throw AudioRecorderError.startFailed
            }

            recording = true
            startHealthMonitoring(id: id)
        } catch {
            if id == captureID { cleanupRecordingState() }
            if error is CancellationError { throw error }
            if let error = error as? AudioRecorderError { throw error }
            throw AudioRecorderError.recorderCreationFailed(underlying: error.localizedDescription)
        }
    }

    /// 返回当前录音电平（0-1 归一化），用于驱动 HUD 声波动画
    @MainActor
    func currentLevel() -> Float {
        guard recording else { return 0 }
        return sampleLock.withLock { latestLevel }
    }

    /// 停止录音并返回录音结果（含音频数据和录音时长）
    @MainActor
    func stopRecording() -> AudioRecordingResult {
        guard recording else {
            cleanupRecordingState()
            return AudioRecordingResult(data: Data(), durationMs: 0)
        }
        recording = false


        let session = captureSession
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        // Barrier: every already accepted PCM callback has returned before finish
        // can flush the streaming processor. Late output is rejected by identity.
        captureQueue.sync {
            if let session, session.isRunning { session.stopRunning() }
            sampleLock.withLock { acceptingOutput = nil }
        }

        let (pcmData, sampleCount) = sampleLock.withLock { (capturedPCMData, capturedSampleCount) }
        let durationMs = sampleCount * 1_000 / Int(Self.sampleRate)
        cleanupRecordingState()

        guard !pcmData.isEmpty else {
            return AudioRecordingResult(data: Data(), durationMs: durationMs, sampleCount: sampleCount)
        }

        let wavData = WAVAudioEncoder.encodePCM16(
            pcmData: pcmData,
            sampleRate: Int(Self.sampleRate),
            channels: Self.channels
        )
        return AudioRecordingResult(data: wavData, durationMs: durationMs, sampleCount: sampleCount)
    }

    @MainActor
    private func cleanupRecordingState() {
        captureID = UUID()
        healthTask?.cancel()
        healthTask = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        callbackLock.withLock { _onPCMChunk = nil }
        if let captureSession {
            // Serialize against a queued/in-progress start, even when isRunning is
            // still false. A cancelled start must not open an orphaned microphone.
            captureQueue.sync {
                if captureSession.isRunning { captureSession.stopRunning() }
            }
        }
        captureSession = nil
        audioOutput = nil
        recording = false
        sampleLock.withLock {
            capturedPCMData.removeAll(keepingCapacity: false)
            capturedSampleCount = 0
            latestLevel = 0
            lastBufferAt = nil
            intervalPeakRMS = 0
            acceptingOutput = nil
        }
    }

    @MainActor
    private func observeCapture(session: AVCaptureSession, device: AVCaptureDevice, id: UUID) {
        let center = NotificationCenter.default
        for (name, reason) in [(AVCaptureSession.runtimeErrorNotification, AudioCaptureInterruption.streamFailed),
                               (AVCaptureSession.wasInterruptedNotification, .interrupted)] {
            observers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reportInterruption(reason, id: id) }
            })
        }
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reportInterruption(.deviceDisconnected, id: id) }
        })
    }

    @MainActor
    private func reportInterruption(_ reason: AudioCaptureInterruption, id: UUID) {
        guard captureID == id, captureSession != nil else { return }
        healthTask?.cancel()
        onCaptureEvent?(.interrupted(reason))
    }

    @MainActor
    private func startHealthMonitoring(id: UUID) {
        healthTask = Task { @MainActor [weak self] in
            var health = AudioCaptureHealth(startedAt: ProcessInfo.processInfo.systemUptime)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, self.captureID == id, self.recording else { return }
                let snapshot = self.sampleLock.withLock {
                    let value = (self.lastBufferAt, self.intervalPeakRMS)
                    self.intervalPeakRMS = 0
                    return value
                }
                if let event = health.evaluate(now: ProcessInfo.processInfo.systemUptime,
                                               lastBufferAt: snapshot.0, peakRMS: snapshot.1) {
                    self.onCaptureEvent?(event)
                    if case .interrupted = event { return }
                }
            }
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pcmData = Self.extractPCMData(from: sampleBuffer),
              !pcmData.isEmpty else {
            return
        }

        let level = Self.calculateLevel(fromPCM16Data: pcmData)
        let accepted = sampleLock.withLock {
            guard acceptingOutput === output else { return false }
            capturedSampleCount += pcmData.count / MemoryLayout<Int16>.size
            if retainFullAudio { capturedPCMData.append(pcmData) }
            latestLevel = level
            lastBufferAt = ProcessInfo.processInfo.systemUptime
            intervalPeakRMS = max(intervalPeakRMS, Self.rms(fromPCM16Data: pcmData))
            return true
        }
        guard accepted else { return }
        let chunkHandler = callbackLock.withLock { _onPCMChunk }
        chunkHandler?(pcmData)
    }

    private static func extractPCMData(from sampleBuffer: CMSampleBuffer) -> Data? {
        if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            if status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 {
                return Data(bytes: dataPointer, count: totalLength)
            }
        }

        var requiredSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard status == noErr, requiredSize > 0 else { return nil }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return nil }

        var data = Data()
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let bufferData = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            data.append(Data(bytes: bufferData, count: Int(buffer.mDataByteSize)))
        }
        _ = retainedBlockBuffer
        return data
    }

    private static func rms(fromPCM16Data data: Data) -> Float {
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            let sum = samples.reduce(Float(0)) { sum, sample in
                let value = Float(sample) / 32768
                return sum + value * value
            }
            return sqrt(sum / Float(samples.count))
        }
    }

    private static func calculateLevel(fromPCM16Data data: Data) -> Float {
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }

            var peak: Float = 0
            var sumSquares: Float = 0
            for sample in samples {
                let value = Float(abs(Int(sample))) / Float(Int16.max)
                peak = max(peak, value)
                sumSquares += value * value
            }

            let rms = sqrt(sumSquares / Float(samples.count))
            let mixed = rms * 0.42 + peak * 0.58
            return min(1, powf(mixed, 0.48))
        }
    }
}

/// 录音结果，包含音频数据和录音时长
struct AudioRecordingResult: Sendable {
    let data: Data
    let durationMs: Int
    let sampleCount: Int

    init(data: Data, durationMs: Int, sampleCount: Int = 0) {
        self.data = data
        self.durationMs = durationMs
        self.sampleCount = sampleCount
    }

    /// 录音时长是否低于短录音阈值（500ms）
    var isShortRecording: Bool {
        durationMs < Int(AudioRecorder.shortRecordingThreshold * 1000)
    }
}

enum AudioRecorderError: LocalizedError {
    case recorderCreationFailed(underlying: String)
    case noInputDevice
    case deviceUnavailable(String)
    case startFailed

    var errorDescription: String? {
        switch self {
        case let .recorderCreationFailed(underlying):
            "无法初始化录音器：\(underlying)"
        case .noInputDevice:
            "未找到可用麦克风"
        case let .deviceUnavailable(name):
            "麦克风不可用：\(name)"
        case .startFailed:
            "录音启动失败"
        }
    }
}
