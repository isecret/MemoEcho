import Foundation

/// One recording owns one instance. The pipeline calls this synchronously from its
/// single audio worker; capture callbacks must only enqueue PCM, never call RNNoise.
final class StreamingAudioPreprocessor {
    typealias FrameProcessor = ([Float]) throws -> [Float]

    enum ProcessingError: Error, Equatable {
        case alreadyFinished
        case incompleteSample
        case invalidFrame
        case unavailable
    }

    private static let frameSize = 480
    private let delaySamples: Int
    private let onFallback: ((String) -> Void)?
    private var frameProcessor: FrameProcessor?
    private var pendingByte: UInt8?
    private var previousSample: Float?
    private var frame: [Float] = []
    // Only the not-yet-emitted samples are retained, including algorithm latency.
    private var uncommitted: [Int16] = []
    private var processedSamples48k = 0
    private var finished = false
    private(set) var inputSampleCount = 0
    private(set) var outputSampleCount = 0
    private(set) var fallbackCode: String?

    var bufferedSampleCount: Int { uncommitted.count }

    /// The bundled RNNoise has the overlap/add and delayed-spectrum stages (20ms).
    /// A different runtime must have its delay revalidated before replacing it.
    convenience init(onFallback: ((String) -> Void)? = nil) {
        self.init(delaySamples48k: 960, loader: {
            let processor = try RNNoiseFrameProcessor()
            return { try processor.process($0) }
        }, onFallback: onFallback)
    }

    /// Injection points for deterministic delay, chunk-boundary and failure tests.
    convenience init(delaySamples48k: Int, frameProcessor: @escaping FrameProcessor,
                     onFallback: ((String) -> Void)? = nil) {
        self.init(delaySamples48k: delaySamples48k, loader: { frameProcessor }, onFallback: onFallback)
    }

    init(delaySamples48k: Int, loader: () throws -> FrameProcessor,
         onFallback: ((String) -> Void)? = nil) {
        precondition(delaySamples48k >= 0 && delaySamples48k <= 4 * Self.frameSize)
        delaySamples = delaySamples48k
        self.onFallback = onFallback
        do {
            frameProcessor = try loader()
        } catch {
            fallbackCode = "rnnoise_load_failed"
            onFallback?("rnnoise_load_failed")
        }
    }

    /// A PCM sample may straddle two Data values. No chunk boundary is audible.
    func process(_ pcm: Data) throws -> Data {
        guard !finished else { throw ProcessingError.alreadyFinished }
        var output = Data()
        output.reserveCapacity(pcm.count)
        for byte in pcm {
            guard let lowByte = pendingByte else {
                pendingByte = byte
                continue
            }
            pendingByte = nil
            let sample = Int16(bitPattern: UInt16(lowByte) | UInt16(byte) << 8)
            inputSampleCount += 1
            guard frameProcessor != nil else {
                append(sample, to: &output)
                continue
            }
            uncommitted.append(sample)
            if let previousSample {
                let next = Float(sample)
                for phase in 0..<3 {
                    frame.append(previousSample + (next - previousSample) * Float(phase) / 3)
                }
                if frame.count == Self.frameSize { processFrame(into: &output) }
            }
            previousSample = frameProcessor == nil ? nil : Float(sample)
        }
        return output
    }

    /// Flush interpolation, a padded final frame and algorithm latency. Padding is
    /// never exposed to ASR: output has exactly the original number of samples.
    func finish() throws -> Data {
        guard !finished else { return Data() }
        guard pendingByte == nil else { throw ProcessingError.incompleteSample }
        finished = true
        var output = Data()
        if let previousSample, frameProcessor != nil {
            frame.append(contentsOf: repeatElement(previousSample, count: 3))
        }
        previousSample = nil
        while frameProcessor != nil && outputSampleCount < inputSampleCount {
            frame.append(contentsOf: repeatElement(0, count: Self.frameSize - frame.count))
            processFrame(into: &output)
        }
        frame.removeAll(keepingCapacity: false)
        uncommitted.removeAll(keepingCapacity: false)
        frameProcessor = nil // destroy RNNoise state and close its library promptly
        return output
    }

    private func processFrame(into output: inout Data) {
        guard let processor = frameProcessor else { return }
        do {
            let processed = try processor(frame)
            guard processed.count == Self.frameSize, processed.allSatisfy(\.isFinite) else {
                throw ProcessingError.invalidFrame
            }
            var emitted = 0
            for index in processed.indices {
                let sourceIndex = processedSamples48k + index - delaySamples
                guard sourceIndex >= 0, sourceIndex % 3 == 0,
                      sourceIndex / 3 < inputSampleCount else { continue }
                append(Int16(max(-32768, min(32767, processed[index]))), to: &output)
                emitted += 1
            }
            uncommitted.removeFirst(emitted)
            processedSamples48k += Self.frameSize
            frame.removeAll(keepingCapacity: true)
        } catch {
            // None of this frame was committed. Re-emit only the pending original
            // samples, then remain in passthrough for the rest of this recording.
            frameProcessor = nil
            fallbackCode = "rnnoise_frame_failed"
            onFallback?("rnnoise_frame_failed")
            for sample in uncommitted { append(sample, to: &output) }
            uncommitted.removeAll(keepingCapacity: false)
            frame.removeAll(keepingCapacity: false)
            previousSample = nil
        }
    }

    private func append(_ sample: Int16, to output: inout Data) {
        let bits = UInt16(bitPattern: sample)
        output.append(UInt8(truncatingIfNeeded: bits))
        output.append(UInt8(truncatingIfNeeded: bits >> 8))
        outputSampleCount += 1
    }
}

/// Keeps the dylib alive for exactly as long as its function pointers and state.
private final class RNNoiseFrameProcessor {
    private typealias Create = @convention(c) (UnsafeRawPointer?) -> OpaquePointer?
    private typealias Destroy = @convention(c) (OpaquePointer?) -> Void
    private typealias Process = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Float>?, UnsafePointer<Float>?) -> Float
    private typealias FrameSize = @convention(c) () -> Int32
    private let library: UnsafeMutableRawPointer
    private let state: OpaquePointer
    private let destroy: Destroy
    private let process: Process

    init() throws {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("rnnoise/lib/librnnoise.dylib").path,
              let library = dlopen(path, RTLD_NOW) else {
            throw StreamingAudioPreprocessor.ProcessingError.unavailable
        }
        guard let createSymbol = dlsym(library, "rnnoise_create"),
              let destroySymbol = dlsym(library, "rnnoise_destroy"),
              let processSymbol = dlsym(library, "rnnoise_process_frame"),
              let sizeSymbol = dlsym(library, "rnnoise_get_frame_size"),
              unsafeBitCast(sizeSymbol, to: FrameSize.self)() == 480 else {
            dlclose(library)
            throw StreamingAudioPreprocessor.ProcessingError.unavailable
        }
        guard let state = unsafeBitCast(createSymbol, to: Create.self)(nil) else {
            dlclose(library)
            throw StreamingAudioPreprocessor.ProcessingError.unavailable
        }
        self.library = library
        self.state = state
        destroy = unsafeBitCast(destroySymbol, to: Destroy.self)
        process = unsafeBitCast(processSymbol, to: Process.self)
    }

    deinit {
        destroy(state)
        dlclose(library)
    }

    func process(_ samples: [Float]) throws -> [Float] {
        var output = [Float](repeating: 0, count: 480)
        let probability = samples.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                process(state, output.baseAddress, input.baseAddress)
            }
        }
        guard probability.isFinite else { throw StreamingAudioPreprocessor.ProcessingError.invalidFrame }
        return output
    }
}
