import Foundation

/// A bundled synthetic phrase, never captured from the user's microphone.
enum ASRValidationAudio {
    static func load(bundle: Bundle = .main) throws -> Data {
        guard let url = bundle.url(forResource: "asr-validation", withExtension: "wav"),
              let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw ServiceProbeFailure(kind: .localFixture, message: "测试语音缺失，请重新安装应用")
        }
        try validate(data)
        return data
    }

    static func validate(_ data: Data) throws {
        let failure = ServiceProbeFailure(kind: .localFixture, message: "测试语音损坏，请重新安装应用")
        guard let pcm = try? WAVAudioDataExtractor.extractPCMData(from: data),
              !pcm.isEmpty, pcm.count % 2 == 0, pcm.contains(where: { $0 != 0 }) else { throw failure }
        let bytes = [UInt8](data)
        func uint16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func uint32(_ offset: Int) -> Int { uint16(offset) | uint16(offset + 2) << 16 }
        var offset = 12
        while offset + 8 <= bytes.count {
            let size = uint32(offset + 4)
            guard size >= 0, offset + 8 + size <= bytes.count else { throw failure }
            if String(bytes: bytes[offset..<offset + 4], encoding: .ascii) == "fmt " {
                guard size >= 16, uint16(offset + 8) == 1, uint16(offset + 10) == 1,
                      uint32(offset + 12) == 16_000, uint16(offset + 22) == 16 else { throw failure }
                return
            }
            offset += 8 + size + size % 2
        }
        throw failure
    }
}
