import Foundation

enum AudioCaptureInterruption: String, Sendable, Equatable {
    case deviceDisconnected, streamFailed, interrupted, stalled

    var message: String {
        switch self {
        case .deviceDisconnected: "麦克风已断开，录音已停止"
        case .streamFailed, .interrupted: "麦克风录音中断，请检查设备"
        case .stalled: "麦克风没有返回音频，录音已停止"
        }
    }
}

enum AudioCaptureEvent: Sendable, Equatable {
    case signalMissing
    case signalRestored
    case interrupted(AudioCaptureInterruption)
}

/// Monotonic-time watchdog. Missing buffers and quiet buffers are different conditions.
struct AudioCaptureHealth {
    static let missingBufferTimeout: TimeInterval = 3
    static let quietTimeout: TimeInterval = 4
    static let quietRMSThreshold: Float = 0.001
    private let startedAt: TimeInterval
    private var quietSince: TimeInterval?
    private var warned = false
    private var failed = false

    init(startedAt: TimeInterval) { self.startedAt = startedAt }

    mutating func evaluate(now: TimeInterval, lastBufferAt: TimeInterval?, peakRMS: Float) -> AudioCaptureEvent? {
        guard !failed else { return nil }
        if now - (lastBufferAt ?? startedAt) >= Self.missingBufferTimeout {
            failed = true
            return .interrupted(.stalled)
        }
        if peakRMS > Self.quietRMSThreshold {
            quietSince = nil
            if warned { warned = false; return .signalRestored }
        } else {
            if quietSince == nil { quietSince = now }
            if !warned, now - (quietSince ?? now) >= Self.quietTimeout {
                warned = true
                return .signalMissing
            }
        }
        return nil
    }
}

/// Keeps sealed audio until its ASR result is accepted. Snapshotting on interruption
/// preserves completed transcripts plus unprocessed audio without waiting for a network call.
final class RecordingRecoveryBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int: SealedSegment] = [:]
    private var completed: [Int: String] = [:]

    func append(_ segment: SealedSegment) {
        guard segment.voicedDetected else { return }
        lock.withLock { pending[segment.index] = segment }
    }

    func complete(index: Int, text: String) {
        lock.withLock {
            pending[index] = nil
            completed[index] = text
        }
    }

    func clear() {
        lock.withLock {
            pending.removeAll()
            completed.removeAll()
        }
    }

    func snapshot() -> (segments: [SealedSegment], transcripts: [String]) {
        lock.withLock {
            (pending.values.sorted { $0.index < $1.index }, completed.keys.sorted().compactMap { completed[$0] })
        }
    }
}
