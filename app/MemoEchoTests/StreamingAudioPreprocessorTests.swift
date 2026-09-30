import Foundation
import XCTest
@testable import MemoEcho

final class StreamingAudioPreprocessorTests: XCTestCase {
    func testArbitraryByteChunksProduceSameOutputAndPreserveEverySample() throws {
        let input = pcm((0..<2_003).map { Int16(($0 * 113) % 24_000 - 12_000) })
        for sizes in [[input.count], [1], [7, 320, 3, 641, 2], [319, 321]] {
            let processor = delayedProcessor(frames: 2)
            let output = try run(input, sizes: sizes, through: processor)
            XCTAssertEqual(output, input, "Chunk sizes: \(sizes)")
            XCTAssertEqual(processor.inputSampleCount, 2_003)
            XCTAssertEqual(processor.outputSampleCount, 2_003)
            XCTAssertEqual(processor.bufferedSampleCount, 0)
        }
    }

    func testSubFrameAndExactFrameEndingsFlushWithoutPaddingOrLostTail() throws {
        for count in [0, 1, 2, 159, 160, 161, 319, 320, 321, 479, 480, 481] {
            let samples = (0..<count).map { Int16($0 + 1) }
            let input = pcm(samples)
            let processor = delayedProcessor(frames: 2)
            XCTAssertEqual(try run(input, sizes: [13], through: processor), input, "Samples: \(count)")
            XCTAssertEqual(try processor.finish(), Data(), "Repeated finish cannot duplicate the tail")
        }
    }

    func testResamplingInterpolationContinuesAcrossChunks() throws {
        var frames: [[Float]] = []
        let processor = StreamingAudioPreprocessor(delaySamples48k: 0, frameProcessor: {
            frames.append($0)
            return $0
        })
        let input = pcm([30, 90, -30])
        XCTAssertEqual(try run(input, sizes: [1], through: processor), input)
        XCTAssertEqual(Array(frames[0].prefix(9)), [30, 50, 70, 90, 50, 10, -30, -30, -30])
        XCTAssertTrue(frames[0].dropFirst(9).allSatisfy { $0 == 0 })
    }

    func testContinuousInputDoesNotRetainRecording() throws {
        let processor = delayedProcessor(frames: 2)
        let chunk = pcm([Int16](repeating: 123, count: 1_600))
        var outputCount = 0
        for _ in 0..<600 { // one minute, bounded residual storage throughout
            outputCount += try processor.process(chunk).count
            XCTAssertLessThanOrEqual(processor.bufferedSampleCount, 481)
        }
        outputCount += try processor.finish().count
        XCTAssertEqual(outputCount, chunk.count * 600)
    }

    func testLoadingFailureFallsBackOnceWithoutLeakingUnderlyingError() throws {
        var codes: [String] = []
        let processor = StreamingAudioPreprocessor(delaySamples48k: 960, loader: {
            throw TestError.synthetic
        }, onFallback: { codes.append($0) })
        let input = pcm([1, -1, .min, .max, 71])
        XCTAssertEqual(try run(input, sizes: [3], through: processor), input)
        XCTAssertEqual(codes, ["rnnoise_load_failed"])
        XCTAssertEqual(processor.fallbackCode, "rnnoise_load_failed")
    }

    func testFrameFailureKeepsCommittedPrefixAndFallsBackForOnlyPendingAudio() throws {
        var calls = 0
        var delayed = [[Float]](repeating: [Float](repeating: 0, count: 480), count: 2)
        var codes: [String] = []
        let processor = StreamingAudioPreprocessor(delaySamples48k: 960, frameProcessor: { frame in
            calls += 1
            if calls == 5 { throw TestError.synthetic }
            delayed.append(frame.map { $0 * 2 })
            return delayed.removeFirst()
        }, onFallback: { codes.append($0) })
        let samples = (0..<1_303).map { Int16($0 - 600) }
        let output = try run(pcm(samples), sizes: [47, 511, 3], through: processor)
        // Frames 3 and 4 committed 320 input samples before frame 5 failed.
        let expected = samples.enumerated().map { $0.offset < 320 ? $0.element * 2 : $0.element }
        XCTAssertEqual(output, pcm(expected))
        XCTAssertEqual(codes, ["rnnoise_frame_failed"])
        XCTAssertEqual(calls, 5)
    }

    func testFlushFailurePreservesUncommittedTail() throws {
        var calls = 0
        let processor = StreamingAudioPreprocessor(delaySamples48k: 960, frameProcessor: { _ in
            calls += 1
            throw TestError.synthetic
        })
        let input = pcm([1, 2, 3])
        XCTAssertEqual(try processor.process(input), Data())
        XCTAssertEqual(try processor.finish(), input)
        XCTAssertEqual(calls, 1)
    }

    func testInvalidFrameOutputFallsBackInsteadOfTrappingOrDroppingSamples() throws {
        for badOutput in [[], [Float](repeating: .nan, count: 480)] {
            let processor = StreamingAudioPreprocessor(delaySamples48k: 0, frameProcessor: { _ in badOutput })
            let input = pcm((0..<501).map(Int16.init))
            XCTAssertEqual(try run(input, sizes: [input.count], through: processor), input)
            XCTAssertEqual(processor.fallbackCode, "rnnoise_frame_failed")
        }
    }

    func testIncompletePCMAndProcessAfterFinishAreExplicitErrors() throws {
        let processor = delayedProcessor(frames: 1)
        _ = try processor.process(Data([1]))
        XCTAssertThrowsError(try processor.finish()) {
            XCTAssertEqual($0 as? StreamingAudioPreprocessor.ProcessingError, .incompleteSample)
        }
        _ = try processor.process(Data([0]))
        XCTAssertEqual(try processor.finish(), Data([1, 0]))
        XCTAssertThrowsError(try processor.process(Data([2, 0]))) {
            XCTAssertEqual($0 as? StreamingAudioPreprocessor.ProcessingError, .alreadyFinished)
        }
    }

    private func delayedProcessor(frames: Int) -> StreamingAudioPreprocessor {
        var delayed = [[Float]](repeating: [Float](repeating: 0, count: 480), count: frames)
        return StreamingAudioPreprocessor(delaySamples48k: frames * 480, frameProcessor: { frame in
            delayed.append(frame)
            return delayed.removeFirst()
        })
    }

    private func run(_ input: Data, sizes: [Int], through processor: StreamingAudioPreprocessor) throws -> Data {
        var output = Data()
        var offset = 0
        var chunk = 0
        while offset < input.count {
            let end = min(input.count, offset + sizes[chunk % sizes.count])
            output.append(try processor.process(input.subdata(in: offset..<end)))
            offset = end
            chunk += 1
        }
        output.append(try processor.finish())
        return output
    }

    private func pcm(_ samples: [Int16]) -> Data {
        Data(samples.flatMap { sample in
            let bits = UInt16(bitPattern: sample)
            return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8)]
        })
    }

    private enum TestError: Error { case synthetic }
}
