import Foundation
import Compression

// Fast, lossless buffer compression, not an image codec. Raw RGBA is retained
// as a fallback when compression cannot reduce the payload. Both paths are bounded.
nonisolated enum LinkPixels {
    static func packet(_ pixels: Data, sequence: UInt32) -> LinkPacket {
        var compressed = Data(count: LinkPacket.frameBytes)
        let count = compressed.withUnsafeMutableBytes { output in
            pixels.withUnsafeBytes { input in
                compression_encode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, output.count,
                    input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZ4)
            }
        }
        if count > 0, count < pixels.count {
            compressed.count = count
            return LinkPacket(kind: .compressedFrame, sequence: sequence, body: compressed)
        }
        return LinkPacket(kind: .frame, sequence: sequence, body: pixels)
    }
    static func decode(_ packet: LinkPacket) throws -> Data {
        if packet.kind == .frame {
            guard packet.body.count == LinkPacket.frameBytes else { throw LinkError.invalidPacket }; return packet.body
        }
        guard packet.kind == .compressedFrame, !packet.body.isEmpty, packet.body.count <= LinkPacket.frameBytes else { throw LinkError.invalidPacket }
        var decoded = Data(count: LinkPacket.frameBytes + 1)
        let count = decoded.withUnsafeMutableBytes { output in
            packet.body.withUnsafeBytes { input in
                compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, output.count,
                    input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZ4)
            }
        }
        guard count == LinkPacket.frameBytes else { throw LinkError.invalidPacket }
        decoded.count = LinkPacket.frameBytes
        return decoded
    }
}
