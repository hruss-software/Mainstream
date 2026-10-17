enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func compute(_ p: UnsafePointer<UInt8>, _ n: Int, seed: UInt32 = 0) -> UInt32 {
        var c = ~seed
        table.withUnsafeBufferPointer { t in
            for i in 0..<n { c = t[Int((c ^ UInt32(p[i])) & 0xff)] ^ (c >> 8) }
        }
        return ~c
    }

    static func compute(_ a: [UInt8]) -> UInt32 {
        a.withUnsafeBufferPointer { compute($0.baseAddress!, a.count) }
    }
}

enum CRC16 {
    /// CRC-16/CCITT-FALSE
    static func compute(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }
}

struct SplitMix64 {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    @inline(__always) mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
