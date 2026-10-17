// Systematic random linear fountain code over GF(2), split into blocks of ≤ maxK symbols.
// Symbol ids < K are the source symbols; ids ≥ K are XOR combinations with
// pseudo-random (density ½) coefficients derived from (session, block, id).

public enum Wire {
    public static let symbolSize = 180
    static let headerSize = 7
    public static let messageSize = headerSize + symbolSize + 4   // 191
    static let maxK = 1024
    static let paddedWords = (symbolSize + 7) / 8                 // 23
}

public struct BlockPlan: Equatable {
    public let length: Int
    public let totalSymbols: Int
    public let blockCount: Int
    public let k: Int

    public init(length: Int) {
        self.length = length
        let n = max(1, (length + Wire.symbolSize - 1) / Wire.symbolSize)
        totalSymbols = n
        blockCount = (n + Wire.maxK - 1) / Wire.maxK
        k = (n + blockCount - 1) / blockCount
    }

    public init(length: Int, blockCount: Int, k: Int) {
        self.length = length
        self.totalSymbols = max(1, (length + Wire.symbolSize - 1) / Wire.symbolSize)
        self.blockCount = blockCount
        self.k = k
    }

    public func symbols(in block: Int) -> Int {
        min(k, totalSymbols - block * k)
    }

    var isValid: Bool {
        blockCount >= 1 && k >= 1 && k <= Wire.maxK && (blockCount - 1) * k < totalSymbols && blockCount * k >= totalSymbols
    }
}

@inline(__always)
func repairCoefficients(session: UInt16, block: Int, id: Int, k: Int, into w: UnsafeMutablePointer<UInt64>) {
    let words = (k + 63) / 64
    var rng = SplitMix64(UInt64(session) << 40 ^ UInt64(block) << 20 ^ UInt64(id) ^ 0x5DEECE66D)
    var any: UInt64 = 0
    for i in 0..<words { w[i] = rng.next(); }
    let rem = k & 63
    if rem != 0 { w[words - 1] &= (UInt64(1) << UInt64(rem)) &- 1 }
    for i in 0..<words { any |= w[i] }
    if any == 0 { let b = id % k; w[b >> 6] |= UInt64(1) << UInt64(b & 63) }
}

final class FountainEncoder {
    let plan: BlockPlan
    let session: UInt16
    private var source: [UInt64]   // totalSymbols rows of paddedWords
    private var coef: [UInt64]

    init(data: [UInt8], session: UInt16) {
        plan = BlockPlan(length: data.count)
        self.session = session
        let pw = Wire.paddedWords
        source = [UInt64](repeating: 0, count: plan.totalSymbols * pw)
        coef = [UInt64](repeating: 0, count: (Wire.maxK + 63) / 64)
        source.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            data.withUnsafeBufferPointer { d in
                for s in 0..<plan.totalSymbols {
                    let off = s * Wire.symbolSize
                    let cnt = min(Wire.symbolSize, data.count - off)
                    if cnt > 0 { (base + s * pw * 8).update(from: d.baseAddress! + off, count: cnt) }
                }
            }
        }
    }

    /// Writes symbol `id` of `block` (symbolSize bytes) into `out`.
    func symbol(block: Int, id: Int, into out: UnsafeMutablePointer<UInt8>) {
        let pw = Wire.paddedWords
        let kb = plan.symbols(in: block)
        let first = block * plan.k
        source.withUnsafeBufferPointer { src in
            if id < kb {
                let p = UnsafeRawPointer(src.baseAddress! + (first + id) * pw).assumingMemoryBound(to: UInt8.self)
                out.update(from: p, count: Wire.symbolSize)
                return
            }
            var acc = [UInt64](repeating: 0, count: pw)
            coef.withUnsafeMutableBufferPointer { cw in
                repairCoefficients(session: session, block: block, id: id, k: kb, into: cw.baseAddress!)
                acc.withUnsafeMutableBufferPointer { a in
                    let words = (kb + 63) / 64
                    for wi in 0..<words {
                        var bits = cw[wi]
                        while bits != 0 {
                            let t = bits.trailingZeroBitCount
                            bits &= bits &- 1
                            let row = src.baseAddress! + (first + wi * 64 + t) * pw
                            for q in 0..<pw { a[q] ^= row[q] }
                        }
                    }
                    let p = UnsafeRawPointer(a.baseAddress!).assumingMemoryBound(to: UInt8.self)
                    out.update(from: p, count: Wire.symbolSize)
                }
            }
        }
    }
}

final class BlockDecoder {
    let k: Int
    let words: Int
    private(set) var rank = 0
    private var coef: [UInt64]
    private var data: [UInt64]
    private var has: [Bool]
    private var tmpC: [UInt64]
    private var tmpD: [UInt64]
    private(set) var solved: [UInt8]? = nil

    init(k: Int) {
        self.k = k
        words = (k + 63) / 64
        coef = [UInt64](repeating: 0, count: k * words)
        data = [UInt64](repeating: 0, count: k * Wire.paddedWords)
        has = [Bool](repeating: false, count: k)
        tmpC = [UInt64](repeating: 0, count: words)
        tmpD = [UInt64](repeating: 0, count: Wire.paddedWords)
    }

    var isComplete: Bool { rank == k }

    /// Adds a packet; returns true if it increased the rank.
    func add(session: UInt16, block: Int, id: Int, payload: UnsafePointer<UInt8>) -> Bool {
        if rank == k { return false }
        let pw = Wire.paddedWords
        let W = words
        for i in 0..<W { tmpC[i] = 0 }
        for i in 0..<pw { tmpD[i] = 0 }
        tmpC.withUnsafeMutableBufferPointer { c in
            if id < k {
                c[id >> 6] = UInt64(1) << UInt64(id & 63)
            } else {
                repairCoefficients(session: session, block: block, id: id, k: k, into: c.baseAddress!)
            }
        }
        tmpD.withUnsafeMutableBytes { r in
            r.baseAddress!.assumingMemoryBound(to: UInt8.self).update(from: payload, count: Wire.symbolSize)
        }
        var innovative = false
        coef.withUnsafeMutableBufferPointer { C in
            data.withUnsafeMutableBufferPointer { D in
                tmpC.withUnsafeMutableBufferPointer { v in
                    tmpD.withUnsafeMutableBufferPointer { d in
                        var wi = 0
                        while wi < W {
                            let x = v[wi]
                            if x == 0 { wi += 1; continue }
                            let p = wi * 64 + x.trailingZeroBitCount
                            if has[p] {
                                let rc = C.baseAddress! + p * W
                                for q in wi..<W { v[q] ^= rc[q] }
                                let rd = D.baseAddress! + p * pw
                                for q in 0..<pw { d[q] ^= rd[q] }
                            } else {
                                (C.baseAddress! + p * W).update(from: v.baseAddress!, count: W)
                                (D.baseAddress! + p * pw).update(from: d.baseAddress!, count: pw)
                                has[p] = true
                                rank += 1
                                innovative = true
                                return
                            }
                        }
                    }
                }
            }
        }
        if rank == k { solve() }
        return innovative
    }

    private func solve() {
        let pw = Wire.paddedWords
        let W = words
        coef.withUnsafeBufferPointer { C in
            data.withUnsafeMutableBufferPointer { D in
                for p in stride(from: k - 1, through: 0, by: -1) {
                    let row = C.baseAddress! + p * W
                    let dp = D.baseAddress! + p * pw
                    // bits above p
                    var wi = p >> 6
                    var first = true
                    while wi < W {
                        var bits = row[wi]
                        if first {
                            let sh = UInt64((p & 63) + 1)
                            bits = sh >= 64 ? 0 : bits & ~((UInt64(1) << sh) &- 1)
                            first = false
                        }
                        while bits != 0 {
                            let t = bits.trailingZeroBitCount
                            bits &= bits &- 1
                            let q = wi * 64 + t
                            let dq = D.baseAddress! + q * pw
                            for z in 0..<pw { dp[z] ^= dq[z] }
                        }
                        wi += 1
                    }
                }
            }
        }
        var out = [UInt8](repeating: 0, count: k * Wire.symbolSize)
        data.withUnsafeBytes { raw in
            let src = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            out.withUnsafeMutableBufferPointer { o in
                for p in 0..<k {
                    (o.baseAddress! + p * Wire.symbolSize).update(from: src + p * pw * 8, count: Wire.symbolSize)
                }
            }
        }
        solved = out
        coef = []
        data = []
    }
}
