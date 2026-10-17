// Rate-1/2, constraint-length-7 convolutional code (generators 171, 133 octal — the
// NASA/DVB code) with optional rate-3/4 puncturing and a soft-decision Viterbi decoder.
// Soft inputs are log-likelihood ratios: positive means "bit is 0".

public enum CodeRate: Sendable {
    case half, threeQuarters, none

    /// Coded bits for `info` input bits (including the 6 tail bits for coded rates).
    func codedLength(_ info: Int) -> Int {
        switch self {
        case .none: return info
        case .half: return 2 * (info + 6)
        case .threeQuarters:
            let t = info + 6
            return (0..<t).reduce(0) { $0 + ($1 % 3 == 2 ? 1 : ($1 % 3 == 1 ? 1 : 2)) }
        }
    }

    var ratio: Double {
        switch self { case .none: return 1; case .half: return 0.5; case .threeQuarters: return 0.75 }
    }
}

enum Convolutional {
    static let g0 = 0o171, g1 = 0o133
    static let out0: [UInt8] = (0..<128).map { UInt8(($0 & g0).nonzeroBitCount & 1) }
    static let out1: [UInt8] = (0..<128).map { UInt8(($0 & g1).nonzeroBitCount & 1) }

    /// Encodes `bits` (0/1), appending six zero tail bits, then punctures.
    static func encode(_ bits: [UInt8], rate: CodeRate) -> [UInt8] {
        if rate == .none { return bits }
        var reg = 0
        var out: [UInt8] = []
        out.reserveCapacity(rate.codedLength(bits.count))
        let input = bits + [UInt8](repeating: 0, count: 6)
        for (t, b) in input.enumerated() {
            reg = ((reg << 1) | Int(b)) & 0x7F
            let a = out0[reg], c = out1[reg]
            switch rate {
            case .half: out.append(a); out.append(c)
            case .threeQuarters:
                // puncture matrix [1 1 0; 1 0 1]
                if t % 3 != 2 { out.append(a) }
                if t % 3 != 1 { out.append(c) }
            case .none: break
            }
        }
        return out
    }

    /// Soft Viterbi decode of `llr` (coded, punctured) back to `info` bits.
    static func decode(_ llr: [Float], info: Int, rate: CodeRate) -> [UInt8] {
        if rate == .none { return llr.map { $0 < 0 ? 1 : 0 } }
        let T = info + 6
        // de-puncture into (A, B) pairs; missing bits carry no information
        var la = [Float](repeating: 0, count: T), lb = la
        var k = 0
        for t in 0..<T {
            switch rate {
            case .half: la[t] = llr[k]; lb[t] = llr[k + 1]; k += 2
            case .threeQuarters:
                if t % 3 != 2 { la[t] = llr[k]; k += 1 }
                if t % 3 != 1 { lb[t] = llr[k]; k += 1 }
            case .none: break
            }
        }
        var pm = [Float](repeating: -1e30, count: 64)
        pm[0] = 0
        var next = pm
        var decisions = [UInt64](repeating: 0, count: T)
        out0.withUnsafeBufferPointer { o0 in
            out1.withUnsafeBufferPointer { o1 in
                for t in 0..<T {
                    let a = la[t], b = lb[t]
                    var d: UInt64 = 0
                    var best: Float = -1e30
                    for ns in 0..<64 {
                        // predecessors differ in the bit shifted out (b = 0 or 1)
                        let r0 = ns, r1 = 64 | ns
                        let m0 = pm[ns >> 1] + (o0[r0] == 0 ? a : -a) + (o1[r0] == 0 ? b : -b)
                        let m1 = pm[(ns >> 1) | 32] + (o0[r1] == 0 ? a : -a) + (o1[r1] == 0 ? b : -b)
                        if m1 > m0 { next[ns] = m1; d |= UInt64(1) << UInt64(ns) } else { next[ns] = m0 }
                        if next[ns] > best { best = next[ns] }
                    }
                    decisions[t] = d
                    for s in 0..<64 { pm[s] = next[s] - best }
                }
            }
        }
        // trace back from the zero state (tail-terminated)
        var out = [UInt8](repeating: 0, count: T)
        var ns = 0
        for t in stride(from: T - 1, through: 0, by: -1) {
            out[t] = UInt8(ns & 1)
            let bit = Int((decisions[t] >> UInt64(ns)) & 1)
            ns = (ns >> 1) | (bit << 5)
        }
        return Array(out.prefix(info))
    }
}
