import Foundation
import XCTest
@testable import MemoEcho

final class AudioPreprocessorTests: XCTestCase {
    func testBundledCoreLoadsAndMatchesChunkedProcessing() throws {
        // Synthetic input only. This uses the signed app's actual core, so a
        // missing resource or silent passthrough cannot satisfy the integration test.
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let manifestData = try Data(contentsOf: resources.appendingPathComponent("rnnoise/build-info.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["inference"] as? String, "mixed-int8")
        XCTAssertTrue((manifest["cflags"] as? [String] ?? []).contains("-DDISABLE_DEBUG_FLOAT"))
        let samples = (0..<32_123).map { index in
            Int16(8_000 * sin(Double(index) * 2 * .pi * 180 / 16_000))
        }
        let input = pcm(samples)
        let batch = try AudioPreprocessor().denoise(wavData: wav(input))
        let stream = StreamingAudioPreprocessor()
        XCTAssertNil(stream.fallbackCode, "Bundled RNNoise must actually load")
        var output = Data()
        for offset in stride(from: 0, to: input.count, by: 641) {
            output.append(try stream.process(input.subdata(in: offset..<min(offset + 641, input.count))))
        }
        output.append(try stream.finish())
        XCTAssertNil(stream.fallbackCode, "The real core must process and flush successfully")
        XCTAssertEqual(output.count, input.count)
        XCTAssertNotEqual(output, input, "Bundled quantized core must transform the synthetic signal")
        XCTAssertEqual(try WAVAudioDataExtractor.extractPCMData(from: batch), output)
    }

    func testBatchMatchesStreamingWithDelayCompensationAndCompleteTail() throws {
        for count in [0, 1, 2, 159, 160, 161, 319, 320, 321, 479, 480, 481, 2_003] {
            let samples = (0..<count).map { Int16(($0 * 113) % 12_000 - 6_000) }
            let input = pcm(samples)
            let batch = AudioPreprocessor(loader: { Self.delayedFrames() })
            let batchPCM = try WAVAudioDataExtractor.extractPCMData(from: batch.denoise(wavData: wav(input)))
            let stream = StreamingAudioPreprocessor(delaySamples48k: 960, frameProcessor: Self.delayedFrames())
            var streamedPCM = Data()
            // Odd byte boundaries also exercise split PCM samples and interpolation.
            for offset in stride(from: 0, to: input.count, by: 37) {
                streamedPCM.append(try stream.process(input.subdata(in: offset..<min(offset + 37, input.count))))
            }
            streamedPCM.append(try stream.finish())
            XCTAssertEqual(batchPCM, streamedPCM, "Samples: \(count)")
            XCTAssertEqual(batchPCM, pcm(samples.map { $0 * 2 }), "No latency, padding or lost tail: \(count)")
            XCTAssertEqual(batchPCM.count, input.count)
        }
    }

    func testEachBatchCallGetsFreshState() throws {
        let batch = AudioPreprocessor(loader: { Self.delayedFrames() })
        let input = wav(pcm([13, -41, 99]))
        let first = try batch.denoise(wavData: input)
        XCTAssertEqual(try batch.denoise(wavData: input), first)
        XCTAssertEqual(try WAVAudioDataExtractor.extractPCMData(from: first), pcm([26, -82, 198]))
    }

    func testLoadingFailureIsAnExplicitPreprocessingError() {
        let batch = AudioPreprocessor(loader: { throw TestError.synthetic })
        assertPreprocessingFailure { try batch.denoise(wavData: wav(pcm([1, 2, 3]))) }
    }

    func testFrameFailureDoesNotReturnCommittedPrefixOrPassthroughAudio() {
        let batch = AudioPreprocessor(loader: {
            var calls = 0
            let delayed = Self.delayedFrames()
            return { frame in
                calls += 1
                // Two frames have already been emitted before this failure.
                if calls == 5 { throw TestError.synthetic }
                return try delayed(frame)
            }
        })
        assertPreprocessingFailure {
            try batch.denoise(wavData: wav(pcm([Int16](repeating: 100, count: 1_600))))
        }
    }

    func testTailFlushFailureIsAnExplicitPreprocessingError() {
        let batch = AudioPreprocessor(loader: { { _ in throw TestError.synthetic } })
        // Three samples are not enough to process a frame until finish().
        assertPreprocessingFailure { try batch.denoise(wavData: wav(pcm([1, 2, 3]))) }
    }

    func testInvalidFramesAreRejectedByBatchInsteadOfFallingBack() {
        for output in [[], [Float](repeating: .nan, count: 480), [Float](repeating: .infinity, count: 480)] {
            let batch = AudioPreprocessor(loader: { { _ in output } })
            assertPreprocessingFailure { try batch.denoise(wavData: wav(pcm([1, 2, 3]))) }
        }
    }

    func testMalformedWAVAndIncompletePCMDoNotReachTheRuntime() {
        let batch = AudioPreprocessor(loader: {
            XCTFail("Invalid audio must be rejected before loading RNNoise")
            return { $0 }
        })
        let truncated = Data(wav(pcm([1, 2, 3])).dropLast())
        for input in [Data(), Data(repeating: 0, count: 44), wav(Data([1])), truncated] {
            assertPreprocessingFailure { try batch.denoise(wavData: input) }
        }
    }

    private static func delayedFrames() -> StreamingAudioPreprocessor.FrameProcessor {
        var pending = [[Float]](repeating: [Float](repeating: 0, count: 480), count: 2)
        return { frame in
            pending.append(frame.map { $0 * 2 })
            return pending.removeFirst()
        }
    }

    private func assertPreprocessingFailure(
        file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Data
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case MemoEchoError.audioPreprocessFailure = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }
    }

    private func wav(_ pcm: Data) -> Data {
        WAVAudioEncoder.encodePCM16(pcmData: pcm, sampleRate: 16_000, channels: 1)
    }

    private func pcm(_ samples: [Int16]) -> Data {
        Data(samples.flatMap { sample in
            let bits = UInt16(bitPattern: sample)
            return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8)]
        })
    }

    private enum TestError: Error { case synthetic }
}
