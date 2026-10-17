// Reed-Solomon over GF(256), primitive polynomial 0x11d, first consecutive root α^0.
// Array index j holds the coefficient of x^(n-1-j); data first, parity last.
// Decoding supports errors and erasures (2·errors + erasures ≤ parity).

final class GF256 {
    static let shared = GF256()
    let exp: [UInt8]   // 512 entries, exp[i] = α^i
    let log: [Int]     // log[0] unused

    private init() {
        var e = [UInt8](repeating: 0, count: 512)
        var l = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            e[i] = UInt8(x)
            l[x] = i
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11d }
        }
        for i in 255..<512 { e[i] = e[i - 255] }
        exp = e
        log = l
    }

    @inline(__always) func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return exp[log[Int(a)] + log[Int(b)]]
    }

    @inline(__always) func div(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 { return 0 }
        return exp[(log[Int(a)] + 255 - log[Int(b)]) % 255]
    }

    @inline(__always) func pow(_ p: Int) -> UInt8 {
        exp[((p % 255) + 255) % 255]
    }
}

public final class ReedSolomon {
    public let parity: Int
    private let gf = GF256.shared
    /// Generator polynomial, descending powers, gen[0] == 1.
    private let gen: [UInt8]
    private let genLog: [Int]

    public init(parity: Int) {
        precondition(parity >= 2 && parity < 255)
        self.parity = parity
        let gf = GF256.shared
        var g: [UInt8] = [1]
        for i in 0..<parity {
            // multiply by (x + α^i)
            var ng = [UInt8](repeating: 0, count: g.count + 1)
            let r = gf.exp[i]
            for j in 0..<g.count {
                ng[j] ^= g[j]
                ng[j + 1] ^= gf.mul(g[j], r)
            }
            g = ng
        }
        gen = g
        genLog = g.map { $0 == 0 ? -1 : gf.log[Int($0)] }
    }

    /// Writes `parity` bytes to `out` for message `msg[0..<k]`.
    public func encode(_ msg: UnsafePointer<UInt8>, count k: Int, parityOut out: UnsafeMutablePointer<UInt8>) {
        let p = parity
        for i in 0..<p { out[i] = 0 }
        gf.exp.withUnsafeBufferPointer { exp in
            genLog.withUnsafeBufferPointer { gl in
                for i in 0..<k {
                    let fb = msg[i] ^ out[0]
                    // shift
                    for j in 0..<(p - 1) { out[j] = out[j + 1] }
                    out[p - 1] = 0
                    if fb != 0 {
                        let lf = gf.log[Int(fb)]
                        for j in 0..<p {
                            let g = gl[j + 1]
                            if g >= 0 { out[j] ^= exp[g + lf] }
                        }
                    }
                }
            }
        }
    }

    public func encode(_ msg: [UInt8]) -> [UInt8] {
        var out = msg + [UInt8](repeating: 0, count: parity)
        let k = msg.count
        out.withUnsafeMutableBufferPointer { b in
            encode(UnsafePointer(b.baseAddress!), count: k, parityOut: b.baseAddress! + k)
        }
        return out
    }

    /// Corrects `cw` (length n) in place. Returns number of corrected symbols, or nil on failure.
    public func decode(_ cw: UnsafeMutablePointer<UInt8>, count n: Int, erasures: [Int] = []) -> Int? {
        let t2 = parity
        let exp = gf.exp
        let log = gf.log
        // Syndromes S_i = r(α^i)
        var synd = [UInt8](repeating: 0, count: t2)
        var allZero = true
        for i in 0..<t2 {
            var acc: UInt8 = 0
            if i == 0 {
                for j in 0..<n { acc ^= cw[j] }
            } else {
                for j in 0..<n {
                    acc = (acc == 0 ? 0 : exp[log[Int(acc)] + i]) ^ cw[j]
                }
            }
            synd[i] = acc
            if acc != 0 { allZero = false }
        }
        if allZero { return 0 }

        let f = erasures.count
        if f > t2 { return nil }
        // Erasure locator Γ(x) = Π (1 + α^p x), ascending.
        var gamma: [UInt8] = [1]
        for j in erasures {
            let xp = gf.pow(n - 1 - j)
            var ng = [UInt8](repeating: 0, count: gamma.count + 1)
            for a in 0..<gamma.count {
                ng[a] ^= gamma[a]
                ng[a + 1] ^= gf.mul(gamma[a], xp)
            }
            gamma = ng
        }
        // Modified syndromes T = Γ·S mod x^2t; sequence T_f..T_{2t-1}.
        var seq = [UInt8](repeating: 0, count: t2 - f)
        for kk in f..<t2 {
            var v: UInt8 = 0
            for a in 0...f where kk - a >= 0 {
                v ^= gf.mul(gamma[a], synd[kk - a])
            }
            seq[kk - f] = v
        }
        // Berlekamp–Massey on seq
        let N = seq.count
        var C = [UInt8](repeating: 0, count: N + 2); C[0] = 1
        var B = [UInt8](repeating: 0, count: N + 2); B[0] = 1
        var L = 0, m = 1
        var b: UInt8 = 1
        for nn in 0..<N {
            var d = seq[nn]
            if L > 0 {
                for i in 1...L { d ^= gf.mul(C[i], seq[nn - i]) }
            }
            if d == 0 {
                m += 1
            } else if 2 * L <= nn {
                let T = C
                let coef = gf.div(d, b)
                for i in 0..<(N + 2 - m) where B[i] != 0 { C[i + m] ^= gf.mul(coef, B[i]) }
                L = nn + 1 - L
                B = T
                b = d
                m = 1
            } else {
                let coef = gf.div(d, b)
                for i in 0..<(N + 2 - m) where B[i] != 0 { C[i + m] ^= gf.mul(coef, B[i]) }
                m += 1
            }
        }
        if 2 * L > N { return nil }
        // Ψ = Λ·Γ
        var psi = [UInt8](repeating: 0, count: L + f + 1)
        for i in 0...L where C[i] != 0 {
            for a in 0...f { psi[i + a] ^= gf.mul(C[i], gamma[a]) }
        }
        let deg = L + f
        if deg == 0 { return nil }
        // Ω = S·Ψ mod x^2t
        var omega = [UInt8](repeating: 0, count: t2)
        for i in 0..<t2 {
            var v: UInt8 = 0
            for a in 0...min(i, deg) { v ^= gf.mul(psi[a], synd[i - a]) }
            omega[i] = v
        }
        // Chien search + Forney
        var positions: [Int] = []
        var mags: [UInt8] = []
        for j in 0..<n {
            let p = n - 1 - j
            let xinvLog = (255 - p) % 255
            // Ψ(X^-1)
            var v: UInt8 = 0
            var dv: UInt8 = 0   // Ψ'(X^-1): odd terms
            for a in 0...deg where psi[a] != 0 {
                let term = exp[log[Int(psi[a])] + (xinvLog * a) % 255]
                v ^= term
                if a & 1 == 1 {
                    // a·Ψ_a x^(a-1) → term / x
                    dv ^= exp[log[Int(psi[a])] + (xinvLog * (a - 1)) % 255]
                }
            }
            if v == 0 {
                if dv == 0 { return nil }
                var ov: UInt8 = 0
                for a in 0..<t2 where omega[a] != 0 {
                    ov ^= exp[log[Int(omega[a])] + (xinvLog * a) % 255]
                }
                // Y = X·Ω(X^-1)/Ψ'(X^-1)
                let y = gf.div(gf.mul(gf.pow(p), ov), dv)
                positions.append(j)
                mags.append(y)
                if positions.count > deg { return nil }
            }
        }
        if positions.count != deg { return nil }
        for (i, j) in positions.enumerated() { cw[j] ^= mags[i] }
        return deg
    }

    public func decode(_ cw: inout [UInt8], erasures: [Int] = []) -> Int? {
        let n = cw.count
        return cw.withUnsafeMutableBufferPointer { decode($0.baseAddress!, count: n, erasures: erasures) }
    }
}
