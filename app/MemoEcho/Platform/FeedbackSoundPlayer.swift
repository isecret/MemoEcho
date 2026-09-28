import AVFoundation
import Foundation
import os

@MainActor
protocol FeedbackSoundPlaying: AnyObject {
    func playStart()
    func playStop()
}

/// 反馈音效播放器，基于 AVAudioEngine 实现音效播放。
///
/// 引擎在每次播放时按需启动，自动适配当前硬件采样率。
/// 提示音时序由会话/HUD 控制；本层每次请求只播放一次。
@MainActor
final class FeedbackSoundPlayer: FeedbackSoundPlaying {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let audioFormat: AVAudioFormat

    private var startBuffer: AVAudioPCMBuffer?
    private var stopBuffer: AVAudioPCMBuffer?
    private var configurationObserver: NotificationObserver?
    private var needsReconnect = false

    private static let logger = Logger(subsystem: "me.wangmao.memoecho", category: "FeedbackSound")

    init() {
        audioFormat = FeedbackSoundDesigner.makePlaybackFormat()

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: audioFormat)

        do {
            startBuffer = try FeedbackSoundAssets.makeBuffer(for: .start)
            stopBuffer = try FeedbackSoundAssets.makeBuffer(for: .stop)
        } catch {
            startBuffer = nil
            stopBuffer = nil
            Self.logger.error("Failed to load UFO feedback audio: \(String(describing: error))")
        }

        configurationObserver = NotificationObserver(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEngineConfigurationChange()
            }
        })

        Self.logger.info("init | startBuffer=\(self.startBuffer != nil) stopBuffer=\(self.stopBuffer != nil)")
    }

    func playStart() {
        play(startBuffer, label: "start")
    }

    func playStop() {
        play(stopBuffer, label: "stop")
    }

    // MARK: - Engine Lifecycle

    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        if needsReconnect {
            playerNode.stop()
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: audioFormat)
            needsReconnect = false
        }

        guard !engine.isRunning else { return true }

        engine.prepare()
        do {
            try engine.start()
            let fmt = engine.outputNode.outputFormat(forBus: 0)
            Self.logger.info(
                "engine started ✓ | sampleRate=\(fmt.sampleRate, format: .fixed(precision: 0)) channels=\(fmt.channelCount)"
            )
            return true
        } catch {
            Self.logger.error("engine start FAILED: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    private func play(_ buffer: AVAudioPCMBuffer?, label: String) -> Bool {
        guard let buffer else {
            Self.logger.error("play(\(label)) | buffer is nil")
            return false
        }
        guard startEngineIfNeeded(), engine.isRunning else {
            Self.logger.error("play(\(label)) | engine NOT running after start attempt")
            return false
        }
        playerNode.stop()
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        playerNode.play()
        Self.logger.info("play(\(label)) | scheduled & playing, node.isPlaying=\(self.playerNode.isPlaying)")
        return playerNode.isPlaying
    }

    private func handleEngineConfigurationChange() {
        needsReconnect = true
        playerNode.stop()
        engine.stop()

        Self.logger.info("engine configuration changed; reconnect on next cue")
    }
}

private final class NotificationObserver: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
