// Compiled with the production StreamingAudioPreprocessor.swift, outside the app.
import Foundation
import Darwin

enum ProbeError: Error { case invalid(String) }

final class NativeFrames {
    typealias Create = @convention(c) (UnsafeRawPointer?) -> OpaquePointer?
    typealias Destroy = @convention(c) (OpaquePointer?) -> Void
    typealias Process = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Float>?, UnsafePointer<Float>?) -> Float
    typealias Size = @convention(c) () -> Int32
    let library: UnsafeMutableRawPointer
    let create: Create
    let destroy: Destroy
    let process: Process
    var state: OpaquePointer
    var output = [Float](repeating: 0, count: 480)

    init(_ path: String) throws {
        guard let library = dlopen(path, RTLD_NOW) else {
            throw ProbeError.invalid(String(cString: dlerror()))
        }
        guard let c = dlsym(library, "rnnoise_create"),
              let d = dlsym(library, "rnnoise_destroy"),
              let p = dlsym(library, "rnnoise_process_frame"),
              let s = dlsym(library, "rnnoise_get_frame_size"),
              unsafeBitCast(s, to: Size.self)() == 480 else {
            dlclose(library)
            throw ProbeError.invalid("RNNoise symbols/frame size")
        }
        let create = unsafeBitCast(c, to: Create.self)
        guard let state = create(nil) else {
            dlclose(library)
            throw ProbeError.invalid("RNNoise create")
        }
        self.library = library
        self.create = create
        self.state = state
        destroy = unsafeBitCast(d, to: Destroy.self)
        process = unsafeBitCast(p, to: Process.self)
    }

    deinit { destroy(state); dlclose(library) }
    func reset() throws {
        guard let replacement = create(nil) else { throw ProbeError.invalid("RNNoise reset") }
        destroy(state)
        state = replacement
    }
    func run(_ samples: UnsafePointer<Float>) throws {
        let probability = output.withUnsafeMutableBufferPointer { process(state, $0.baseAddress, samples) }
        // Match the production loader. StreamingAudioPreprocessor validates the
        // output samples; scanning here too would add work absent from the app.
        guard probability.isFinite else {
            throw ProbeError.invalid("Non-finite output")
        }
    }
    func frame(_ samples: [Float]) throws -> [Float] {
        guard samples.count == 480 else { throw ProbeError.invalid("Frame size") }
        try samples.withUnsafeBufferPointer { try run($0.baseAddress!) }
        return output
    }
}

func usage() -> rusage {
    var value = rusage()
    getrusage(RUSAGE_SELF, &value)
    return value
}
func cpu(_ value: rusage) -> Double {
    Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
        + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
}
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func residentBytes() throws -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { throw ProbeError.invalid("task_info RSS") }
    return info.resident_size
}
func readPCM(_ path: String) throws -> Data {
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i+1]) << 8 }
    func u32(_ i: Int) -> Int { u16(i) | u16(i+2) << 16 }
    guard bytes.count >= 44, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
          String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else {
        throw ProbeError.invalid("WAV container")
    }
    var offset = 12
    var validFormat = false
    var pcm: Data?
    while offset + 8 <= bytes.count {
        let count = u32(offset+4), start = offset+8
        guard count <= bytes.count-start else { throw ProbeError.invalid("WAV chunk") }
        let tag = String(bytes: bytes[offset..<offset+4], encoding: .ascii)
        if tag == "fmt " {
            guard count >= 16, u16(start) == 1, u16(start+2) == 1,
                  u32(start+4) == 16000, u16(start+14) == 16 else {
                throw ProbeError.invalid("Expected PCM16 mono 16kHz")
            }
            validFormat = true
        } else if tag == "data" { pcm = Data(bytes[start..<start+count]) }
        offset = start + count + (count % 2)
    }
    guard validFormat, let pcm, !pcm.isEmpty, pcm.count % 2 == 0 else {
        throw ProbeError.invalid("WAV PCM missing")
    }
    return pcm
}
func writeWAV(_ pcm: Data, _ path: String) throws {
    var result = Data()
    func string(_ value: String) { result.append(contentsOf: value.utf8) }
    func u16(_ value: Int) { result.append(UInt8(truncatingIfNeeded: value)); result.append(UInt8(truncatingIfNeeded: value >> 8)) }
    func u32(_ value: Int) { u16(value); u16(value >> 16) }
    string("RIFF"); u32(36+pcm.count); string("WAVEfmt "); u32(16)
    u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
    string("data"); u32(pcm.count); result.append(pcm)
    try result.write(to: URL(fileURLWithPath: path), options: .atomic)
}
func pipeline(_ native: NativeFrames) throws -> StreamingAudioPreprocessor {
    try StreamingAudioPreprocessor.requiringDenoising(delaySamples48k: 960, loader: {
        { try native.frame($0) }
    })
}

@main struct Benchmark {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 4 else { throw ProbeError.invalid("LIB core|pipeline|process INPUT.wav [OUTPUT.wav]") }
        let mode = args[2], pcm = try readPCM(args[3])
        var input48k: [Float] = []
        var chunks: [Data] = []
        if mode == "core" {
            let bytes = [UInt8](pcm)
            let samples = stride(from: 0, to: bytes.count, by: 2).map {
                Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0+1]) << 8))
            }
            input48k.reserveCapacity(samples.count*3+480)
            for i in samples.indices {
                let next = samples[min(i+1, samples.count-1)]
                for phase in 0..<3 { input48k.append(samples[i] + (next-samples[i])*Float(phase)/3) }
            }
            if input48k.count % 480 != 0 {
                input48k.append(contentsOf: repeatElement(0, count: 480-input48k.count%480))
            }
        } else {
            chunks = stride(from: 0, to: pcm.count, by: 640).map { pcm.subdata(in: $0..<min($0+640, pcm.count)) }
        }
        var elapsed: [Double] = []
        elapsed.reserveCapacity(max(input48k.count/480, chunks.count)+1)
        let beforeLoad = usage()
        let residentBeforeLoad = try residentBytes()
        let loadStart = now()
        var native: NativeFrames? = try NativeFrames(args[1])
        let loadSeconds = now()-loadStart
        if mode == "process" {
            guard args.count == 5 else { throw ProbeError.invalid("Output required") }
            let processor = try pipeline(native!)
            var output = Data()
            for chunk in chunks { output.append(try processor.process(chunk)) }
            output.append(try processor.finish())
            guard output.count == pcm.count, processor.fallbackCode == nil else { throw ProbeError.invalid("Output count/fallback") }
            try writeWAV(output, args[4])
            return
        }
        guard mode == "core" || mode == "pipeline" else { throw ProbeError.invalid("Mode") }
        // Warm every selected inference path, then reset recurrent state.
        if mode == "core", let native {
            try input48k.withUnsafeBufferPointer { samples in
                for offset in stride(from: 0, to: min(input48k.count, 96000), by: 480) {
                    try native.run(samples.baseAddress!.advanced(by: offset))
                }
            }
        } else {
            let warm = try pipeline(native!)
            for chunk in chunks.prefix(100) { _ = try warm.process(chunk) }
            _ = try warm.finish()
        }
        try native!.reset()
        let processor = mode == "pipeline" ? try pipeline(native!) : nil
        if processor != nil { native = nil } // finish owns destroy/dlclose, as in the app
        let residentAfterWarmup = try residentBytes()
        let warmUsage = usage()
        let startCPU = cpu(warmUsage), startWall = now()
        var checksum = 0.0, outputBytes = 0
        if mode == "core", let native {
            try input48k.withUnsafeBufferPointer { samples in
                for offset in stride(from: 0, to: input48k.count, by: 480) {
                    let start = now()
                    try native.run(samples.baseAddress!.advanced(by: offset))
                    elapsed.append(now()-start)
                    checksum += Double(native.output[120])
                }
            }
        } else if let processor {
            for chunk in chunks {
                let start = now()
                let output = try processor.process(chunk)
                elapsed.append(now()-start)
                outputBytes += output.count
                checksum += Double(output.first ?? 0)
            }
            let start = now()
            let tail = try processor.finish()
            elapsed.append(now()-start)
            outputBytes += tail.count
            guard outputBytes == pcm.count, processor.fallbackCode == nil else { throw ProbeError.invalid("Output count/fallback") }
        }
        let wallSeconds = now()-startWall, final = usage(), cpuSeconds = cpu(final)-startCPU
        let residentAfterProcessing = try residentBytes()
        guard checksum.isFinite, native?.output.allSatisfy(\.isFinite) ?? true else {
            throw ProbeError.invalid("Non-finite final output")
        }
        elapsed.sort()
        let result: [String: Any] = [
            "mode": mode, "audio_seconds": Double(pcm.count)/32000,
            "cpu_seconds": cpuSeconds, "wall_seconds": wallSeconds,
            "cpu_realtime_factor": cpuSeconds/(Double(pcm.count)/32000),
            "call_p50_ms": elapsed[elapsed.count/2]*1000,
            "call_p95_ms": elapsed[min(elapsed.count-1, Int(Double(elapsed.count)*0.95))]*1000,
            "call_max_ms": elapsed.last!*1000, "calls": elapsed.count,
            "peak_rss_before_load_bytes": beforeLoad.ru_maxrss,
            "peak_rss_after_warmup_bytes": warmUsage.ru_maxrss,
            "peak_rss_bytes": final.ru_maxrss, "load_seconds": loadSeconds,
            "resident_before_load_bytes": residentBeforeLoad,
            "resident_after_warmup_bytes": residentAfterWarmup,
            "resident_after_processing_bytes": residentAfterProcessing,
            "checksum": checksum, "output_bytes": outputBytes
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
