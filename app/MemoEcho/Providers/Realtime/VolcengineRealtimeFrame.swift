import Foundation
import zlib

/// V3 full-client/audio-only and full-server framing. All multi-byte integers are big-endian.
enum VolcengineRealtimeFrame {
    static func encode(type: UInt8, sequence: Int32, payload: Data, json: Bool) throws -> Data {
        let compressed = try gzip(payload)
        let server = type == 9
        let flags: UInt8 = (sequence < 0 ? 2 : 0) | (server ? 1 : 0)
        var data = Data([0x11, (type << 4) | flags, json ? 0x11 : 0x01, 0])
        if server { append(UInt32(bitPattern: sequence), to: &data) }
        append(UInt32(compressed.count), to: &data)
        data.append(compressed)
        return data
    }
    static func decode(_ data: Data) throws -> (payload: Data, final: Bool) {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] >> 4 == 1 else { throw RealtimeASRError.invalidResponse }
        let headerSize = Int(bytes[0] & 0x0F) * 4
        guard headerSize >= 4, bytes.count >= headerSize + 4 else { throw RealtimeASRError.invalidResponse }
        let type = bytes[1] >> 4
        let flags = bytes[1] & 0x0F
        guard flags <= 3, type == 9 || type == 15 else { throw RealtimeASRError.invalidResponse }
        if type == 15 { throw RealtimeASRError.serviceRejected }
        var offset = headerSize
        if flags & 1 != 0 { offset += 4 }
        guard bytes.count >= offset + 4 else { throw RealtimeASRError.invalidResponse }
        let length = Int(read(bytes, at: offset))
        offset += 4
        guard length <= 1_048_576, bytes.count == offset + length, bytes[2] >> 4 == 1 else { throw RealtimeASRError.invalidResponse }
        let payload = Data(bytes[offset...])
        let compression = bytes[2] & 0x0F
        guard compression == 0 || compression == 1 else { throw RealtimeASRError.invalidResponse }
        return (compression == 1 ? try gunzip(payload) : payload, flags & 2 != 0)
    }
    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    private static func read(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    static func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw RealtimeASRError.invalidResponse }
        defer { deflateEnd(&stream) }
        return try transform(data, stream: &stream, decompress: false)
    }
    static func gunzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw RealtimeASRError.invalidResponse }
        defer { inflateEnd(&stream) }
        return try transform(data, stream: &stream, decompress: true)
    }
    private static func transform(_ data: Data, stream: inout z_stream, decompress: Bool) throws -> Data {
        try data.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: source.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data()
            var status: Int32 = Z_OK
            repeat {
                var buffer = [UInt8](repeating: 0, count: 16_384)
                let produced = buffer.withUnsafeMutableBytes { destination -> Int in
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    status = decompress ? inflate(&stream, Z_NO_FLUSH) : deflate(&stream, Z_FINISH)
                    return destination.count - Int(stream.avail_out)
                }
                guard status == Z_OK || status == Z_STREAM_END, result.count + produced <= 1_048_576 else { throw RealtimeASRError.invalidResponse }
                result.append(contentsOf: buffer.prefix(produced))
            } while status != Z_STREAM_END
            guard stream.avail_in == 0 else { throw RealtimeASRError.invalidResponse }
            return result
        }
    }
}
