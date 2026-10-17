import Foundation
import Compression

/// Lossless compression of payloads before they are sent. Small payloads use LZMA (best ratio),
/// large ones LZFSE (fast); data that doesn't shrink (JPEG, HEIC, video, archives) goes as is.
enum Packing: UInt8 {
    case none = 0, lzfse = 1, lzma = 2

    var algorithm: compression_algorithm? {
        switch self {
        case .none: return nil
        case .lzfse: return COMPRESSION_LZFSE
        case .lzma: return COMPRESSION_LZMA
        }
    }

    /// Largest payload we will expand on receipt.
    static let maxExpanded = 1 << 30

    /// Returns the packed bytes and method, or nil when packing doesn't save at least 3%.
    static func pack(_ data: [UInt8]) -> (Packing, [UInt8])? {
        guard data.count >= 64 else { return nil }
        let method: Packing = data.count <= 4 << 20 ? .lzma : .lzfse
        // a quick trial on the first 256 kB skips media that won't compress
        if data.count > 1 << 20, let trial = encode(Array(data.prefix(256 << 10)), method), trial.count > (256 << 10) * 95 / 100 { return nil }
        guard let out = encode(data, method), out.count < data.count * 97 / 100 else { return nil }
        return (method, out)
    }

    private static func encode(_ src: [UInt8], _ method: Packing) -> [UInt8]? {
        guard let algo = method.algorithm else { return nil }
        var dst = [UInt8](repeating: 0, count: src.count)
        let n = dst.withUnsafeMutableBufferPointer { d in
            src.withUnsafeBufferPointer { s in compression_encode_buffer(d.baseAddress!, src.count, s.baseAddress!, src.count, nil, algo) }
        }
        guard n > 0 else { return nil }
        dst.removeSubrange(n...)
        return dst
    }

    /// Expands to exactly `length` bytes, or nil (corrupt data, or a size we won't allocate).
    func unpack(_ src: [UInt8], length: Int) -> [UInt8]? {
        guard let algo = algorithm else { return src }
        guard length > 0, length <= Packing.maxExpanded else { return nil }
        var dst = [UInt8](repeating: 0, count: length)
        let n = dst.withUnsafeMutableBufferPointer { d in
            src.withUnsafeBufferPointer { s in compression_decode_buffer(d.baseAddress!, length, s.baseAddress!, src.count, nil, algo) }
        }
        return n == length ? dst : nil
    }
}
