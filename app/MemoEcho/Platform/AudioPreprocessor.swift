import Foundation

/// Batch WAV adapter for the same bounded RNNoise pipeline used during recording.
/// Failures remain explicit; the caller owns any fallback to the original audio.
final class AudioPreprocessor: Sendable {
    private let delaySamples48k: Int
    private let loader: @Sendable () throws -> StreamingAudioPreprocessor.FrameProcessor

    init(
        delaySamples48k: Int = StreamingAudioPreprocessor.rnnoiseDelaySamples48k,
        loader: @escaping @Sendable () throws -> StreamingAudioPreprocessor.FrameProcessor = {
            try StreamingAudioPreprocessor.loadFrameProcessor()
        }
    ) {
        self.delaySamples48k = delaySamples48k
        self.loader = loader
    }

    /// Process 16 kHz mono PCM16 WAV without materializing a 48 kHz recording.
    /// Final-frame padding and RNNoise latency are trimmed to the original length.
    func denoise(wavData: Data) throws -> Data {
        let pcm: Data
        do {
            pcm = try WAVAudioDataExtractor.extractPCMData(from: wavData)
        } catch {
            throw MemoEchoError.audioPreprocessFailure(message: "WAV 音频数据无效")
        }
        guard pcm.count.isMultiple(of: 2) else {
            throw MemoEchoError.audioPreprocessFailure(message: "PCM 样本不完整")
        }

        do {
            let processor = try StreamingAudioPreprocessor.requiringDenoising(
                delaySamples48k: delaySamples48k, loader: loader
            )
            var output = try processor.process(pcm)
            output.append(try processor.finish())
            return WAVAudioEncoder.encodePCM16(pcmData: output, sampleRate: 16_000, channels: 1)
        } catch {
            throw MemoEchoError.audioPreprocessFailure(message: "RNNoise 降噪处理失败")
        }
    }
}
