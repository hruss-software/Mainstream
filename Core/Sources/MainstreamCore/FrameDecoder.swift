import Foundation

/// A borrowed BGRA8 camera frame.
public struct BGRAFrame {
    public let base: UnsafePointer<UInt8>
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public init(base: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) {
        self.base = base; self.width = width; self.height = height; self.bytesPerRow = bytesPerRow
    }

    /// Bilinear sample at continuous coords (pixel i covers [i, i+1)); returns (r, g, b).
    @inline(__always) func sample(_ x: Double, _ y: Double) -> (Float, Float, Float) {
        var u = x - 0.5, v = y - 0.5
        if u < 0 { u = 0 } else if u > Double(width - 2) { u = Double(width - 2) }
        if v < 0 { v = 0 } else if v > Double(height - 2) { v = Double(height - 2) }
        let x0 = Int(u), y0 = Int(v)
        let fx = Float(u - Double(x0)), fy = Float(v - Double(y0))
        let p = base + y0 * bytesPerRow + x0 * 4
        let q = p + bytesPerRow
        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
        let b = w00 * Float(p[0]) + w10 * Float(p[4]) + w01 * Float(q[0]) + w11 * Float(q[4])
        let g = w00 * Float(p[1]) + w10 * Float(p[5]) + w01 * Float(q[1]) + w11 * Float(q[5])
        let r = w00 * Float(p[2]) + w10 * Float(p[6]) + w01 * Float(q[2]) + w11 * Float(q[6])
        return (r, g, b)
    }

    @inline(__always) func luma(_ x: Double, _ y: Double) -> Float {
        let (r, g, b) = sample(x, y)
        return (r + 2 * g + b) * 0.25
    }
}

public struct FrameStats: Sendable {
    public var found = false
    public var levelIndex: Int? = nil
    public var slots = 0
    public var decoded = 0
    public var corrections = 0       // symbols corrected over decoded codewords
    public var parity = 0
    public var markersFound = 0
    public var markersTotal = 0
    public var corners: [Pt] = []    // TL, TR, BR, BL in image coordinates
}

public final class FrameDecoder {
    private var finder: FinderDetector? = nil
    private var lastRotation = 0
    public var concurrent = true
    /// Decision-feedback cancellation of inter-cell blur.
    public var equalize = true
    public var debug = false

    public init() {}

    public func decode(_ f: BGRAFrame) -> (packets: [Packet], stats: FrameStats) {
        var stats = FrameStats()
        // 1. downsampled luma
        let d = max(1, max(f.width, f.height) / 960)
        let w = f.width / d, h = f.height / d
        if finder == nil || finder!.w != w || finder!.h != h { finder = FinderDetector(w: w, h: h) }
        let fd = finder!
        fd.lum.withUnsafeMutableBufferPointer { L in
            let half = d / 2
            for y in 0..<h {
                let sy = min(f.height - 2, y * d + half)
                let row = f.base + sy * f.bytesPerRow
                let row2 = row + f.bytesPerRow
                for x in 0..<w {
                    let sx = min(f.width - 2, x * d + half) * 4
                    let a = Int(row[sx]) + 2 * Int(row[sx + 1]) + Int(row[sx + 2])
                    let b = Int(row2[sx + 4]) + 2 * Int(row2[sx + 5]) + Int(row2[sx + 6])
                    L[y * w + x] = UInt8((a + b) >> 3)
                }
            }
        }
        let cands = fd.detect()
        if debug {
            for c in cands.sorted(by: { $0.count > $1.count }).prefix(12) {
                print(String(format: "cand %.0f,%.0f m %.1f n %d", c.x * Double(d), c.y * Double(d), c.module * Double(d), c.count))
            }
        }
        guard let quad = FinderDetector.selectQuad(cands) else { return ([], stats) }
        if debug { print("quad", quad.map { "\(Int($0.x * Double(d))),\(Int($0.y * Double(d)))" }) }
        let pts = quad.map { Pt($0.x * Double(d), $0.y * Double(d)) }
        let modules = quad.map { $0.module * Double(d) }

        // 2. orientation + header
        let unit = [Pt(0, 0), Pt(1, 0), Pt(1, 1), Pt(0, 1)]
        var found: (Homography, Int, Int, Int)? = nil
        for t in 0..<4 {
            let r = (lastRotation + t) % 4
            let c = (0..<4).map { pts[(r + $0) % 4] }
            let mods = (0..<4).map { modules[(r + $0) % 4] }
            guard let H = Homography.from(unit, c) else { continue }
            if let (lv, asp) = readHeader(f, H, corners: c, modules: mods) {
                found = (H, lv, asp, r)
                break
            }
        }
        guard let (H, levelIndex, aspect, rot) = found else { return ([], stats) }
        lastRotation = rot
        stats.found = true
        stats.levelIndex = levelIndex
        stats.corners = (0..<4).map { pts[(rot + $0) % 4] }
        let L = FrameLayout.get(level: levelIndex, aspect: aspect)
        stats.slots = L.slots
        stats.parity = L.level.parity

        let fc = 3.5 * Double(L.m)
        let spanX = Double(L.cols) - 2 * fc, spanY = Double(L.rows) - 2 * fc
        let G = H.after(.scaleTranslate(sx: 1 / spanX, sy: 1 / spanY, tx: -fc / spanX, ty: -fc / spanY))
        let jc = G.jacobian(Double(L.cols) / 2, Double(L.rows) / 2)
        let cellPx = sqrt(abs(jc.0 * jc.3 - jc.1 * jc.2))
        if cellPx < 1.4 { return ([], stats) }

        // 3. alignment refinement
        let (dispX, dispY) = alignment(f, L, G, cellPx: cellPx, stats: &stats)

        // 4. sample cells
        let C = L.level.bpc
        let N = L.cols * L.rows
        var vals = [Float](repeating: 0, count: N * C)
        let nx = L.latX.count - 1, ny = L.latY.count - 1
        var colIdx = [Int](repeating: 0, count: L.cols), colF = [Double](repeating: 0, count: L.cols)
        var rowIdx = [Int](repeating: 0, count: L.rows), rowF = [Double](repeating: 0, count: L.rows)
        func locate(_ v: Double, _ lat: [Double], _ n: Int) -> (Int, Double) {
            var i = 0
            while i < n - 1 && v >= lat[i + 1] { i += 1 }
            let fr = (v - lat[i]) / (lat[i + 1] - lat[i])
            return (i, min(1, max(0, fr)))
        }
        for x in 0..<L.cols { (colIdx[x], colF[x]) = locate(Double(x) + 0.5, L.latX, nx) }
        for y in 0..<L.rows { (rowIdx[y], rowF[y]) = locate(Double(y) + 0.5, L.latY, ny) }
        let lw = L.latX.count
        let r = 0.22 * cellPx
        let cells = L.dataCells
        let chunk = 2048
        let chunks = (cells.count + chunk - 1) / chunk
        vals.withUnsafeMutableBufferPointer { V in
            let vp = V.baseAddress!
            let work: (Int) -> Void = { ci in
                for k in (ci * chunk)..<min(cells.count, (ci + 1) * chunk) {
                    let c = Int(cells[k])
                    let x = c % L.cols, y = c / L.cols
                    let p = G.apply(Double(x) + 0.5, Double(y) + 0.5)
                    let i = colIdx[x], j = rowIdx[y], fx = colF[x], fy = rowF[y]
                    let a = j * lw + i
                    let ddx = (dispX[a] * (1 - fx) + dispX[a + 1] * fx) * (1 - fy) + (dispX[a + lw] * (1 - fx) + dispX[a + lw + 1] * fx) * fy
                    let ddy = (dispY[a] * (1 - fx) + dispY[a + 1] * fx) * (1 - fy) + (dispY[a + lw] * (1 - fx) + dispY[a + lw + 1] * fx) * fy
                    let px = p.x + ddx, py = p.y + ddy
                    var (R, Gc, B) = f.sample(px, py)
                    let s1 = f.sample(px - r, py - r), s2 = f.sample(px + r, py - r)
                    let s3 = f.sample(px - r, py + r), s4 = f.sample(px + r, py + r)
                    R = (2 * R + s1.0 + s2.0 + s3.0 + s4.0) / 6
                    Gc = (2 * Gc + s1.1 + s2.1 + s3.1 + s4.1) / 6
                    B = (2 * B + s1.2 + s2.2 + s3.2 + s4.2) / 6
                    switch C {
                    case 1: vp[c] = (R + Gc + B) / 3
                    case 2: vp[c * 2] = Gc; vp[c * 2 + 1] = (R + B) / 2
                    default: vp[c * 3] = R; vp[c * 3 + 1] = Gc; vp[c * 3 + 2] = B
                    }
                }
            }
            if concurrent { DispatchQueue.concurrentPerform(iterations: chunks, execute: work) }
            else { for ci in 0..<chunks { work(ci) } }
        }

        // 5. local normalisation
        normalise(&vals, L, C)
        // 6. blind crosstalk correction
        if C > 1 { decorrelate(&vals, L, C) }
        if equalize { equalise(&vals, L, C) }

        // 7. codewords
        var packets = [Packet?](repeating: nil, count: L.slots)
        var corr = [Int](repeating: 0, count: L.slots)
        let n = L.n
        let cps = L.cellsPerSlot
        vals.withUnsafeBufferPointer { V in
            let vp = V.baseAddress!
            packets.withUnsafeMutableBufferPointer { pk in
                corr.withUnsafeMutableBufferPointer { cr in
                    let pkp = pk.baseAddress!, crp = cr.baseAddress!
                    let work: (Int) -> Void = { s in
                        var cw = [UInt8](repeating: 0, count: n)
                        var rel = [Float](repeating: 0, count: n)
                        let base = s * cps
                        var ib = 0
                        for i in 0..<n {
                            var byte: UInt8 = 0
                            var mr: Float = .greatestFiniteMagnitude
                            for _ in 0..<8 {
                                let cell = Int(cells[base + ib / C])
                                let v = vp[cell * C + ib % C]
                                byte = byte << 1 | (v > 0 ? 1 : 0)
                                let a = abs(v)
                                if a < mr { mr = a }
                                ib += 1
                            }
                            cw[i] = byte ^ L.scramble[s * n + i]
                            rel[i] = mr
                        }
                        let (p, c) = self.decodeCodeword(cw, rel, L)
                        pkp[s] = p
                        crp[s] = c
                    }
                    if concurrent { DispatchQueue.concurrentPerform(iterations: L.slots, execute: work) }
                    else { for s in 0..<L.slots { work(s) } }
                }
            }
        }
        var out: [Packet] = []
        for s in 0..<L.slots {
            if let p = packets[s] {
                out.append(p)
                stats.corrections += corr[s]
            }
        }
        stats.decoded = out.count
        return (out, stats)
    }

    private func decodeCodeword(_ cw0: [UInt8], _ rel: [Float], _ L: FrameLayout) -> (Packet?, Int) {
        var cw = cw0
        let n = L.n
        if let c = L.rs.decode(&cw), let p = cw.withUnsafeBufferPointer({ parseMessage($0.baseAddress!) }) {
            return (p, c)
        }
        let order = (0..<n).sorted { rel[$0] < rel[$1] }
        let t2 = L.level.parity
        for f in [t2 / 2, (t2 * 3) / 4, t2 - 2] {
            cw = cw0
            let er = Array(order.prefix(f))
            if let c = L.rs.decode(&cw, erasures: er), let p = cw.withUnsafeBufferPointer({ parseMessage($0.baseAddress!) }) {
                return (p, c)
            }
        }
        return (nil, 0)
    }

    // MARK: header

    private func readHeader(_ f: BGRAFrame, _ H: Homography, corners c: [Pt], modules: [Double]) -> (Int, Int)? {
        var black: Float = 0, white: Float = 0
        for i in 0..<4 {
            let p = c[i]
            let q = c[(i + 1) % 4], o = c[(i + 3) % 4]
            let centre = f.luma(p.x, p.y)
            var ring: Float = 0
            for nb in [q, o] {
                let dx = nb.x - p.x, dy = nb.y - p.y
                let l = hypot(dx, dy)
                ring += f.luma(p.x + dx / l * 2 * modules[i], p.y + dy / l * 2 * modules[i]) / 2
            }
            black += centre; white += ring
        }
        black /= 4; white /= 4
        if white - black < 12 { return nil }
        let thr = (black + white) / 2
        let bw = (FrameLayout.headerS1 - FrameLayout.headerS0) / Double(FrameLayout.headerBits)
        var raw = [Bool]()   // true = dark
        for i in 0..<FrameLayout.headerBits {
            let s = FrameLayout.headerS0 + (Double(i) + 0.5) * bw
            let p = H.apply(s, 0)
            let q1 = H.apply(s - bw * 0.2, 0), q2 = H.apply(s + bw * 0.2, 0)
            let v = (2 * f.luma(p.x, p.y) + f.luma(q1.x, q1.y) + f.luma(q2.x, q2.y)) / 4
            raw.append(v < thr)
        }
        return FrameLayout.parseHeader(raw)
    }

    // MARK: alignment

    private static let template: [(Int, Int, Float)] = {
        var t: [(Int, Int, Float)] = []
        for dy in -2...2 { for dx in -2...2 {
            let r = max(abs(dx), abs(dy))
            t.append((dx, dy, r == 1 ? 1 : -1))
        } }
        let mean = t.reduce(Float(0)) { $0 + $1.2 } / 25
        return t.map { ($0.0, $0.1, $0.2 - mean) }
    }()

    private func alignment(_ f: BGRAFrame, _ L: FrameLayout, _ G: Homography, cellPx: Double,
                           stats: inout FrameStats) -> ([Double], [Double]) {
        let lw = L.latX.count, lh = L.latY.count
        var dx = [Double](repeating: 0, count: lw * lh)
        var dy = [Double](repeating: 0, count: lw * lh)
        var valid = [Bool](repeating: false, count: lw * lh)
        for j in [0, lh - 1] { for i in [0, lw - 1] { valid[j * lw + i] = true } }

        let tpl = FrameDecoder.template
        let tnorm = sqrt(tpl.reduce(Float(0)) { $0 + $1.2 * $1.2 })
        var idx: [Int] = []
        for a in 0..<(lw * lh) where L.markerAt[a] { idx.append(a) }
        stats.markersTotal = idx.count
        var res = [(Double, Double, Bool)](repeating: (0, 0, false), count: idx.count)
        res.withUnsafeMutableBufferPointer { R in
            let rp = R.baseAddress!
            let work: (Int) -> Void = { q in
                let a = idx[q]
                let i = a % lw, j = a / lw
                let mx = L.markerCX[i], my = L.markerCY[j]
                let p = G.apply(mx, my)
                let J = G.jacobian(mx, my)
                func score(_ ox: Double, _ oy: Double) -> Float {
                    var s: Float = 0, s1: Float = 0, s2: Float = 0
                    for (tx, ty, wv) in tpl {
                        let cx = Double(tx) + ox, cy = Double(ty) + oy
                        let v = f.luma(p.x + J.0 * cx + J.1 * cy, p.y + J.2 * cx + J.3 * cy)
                        s += wv * v; s1 += v; s2 += v * v
                    }
                    let varr = s2 - s1 * s1 / 25
                    if varr <= 1e-3 { return -1 }
                    return s / (tnorm * sqrt(varr))
                }
                var best: Float = -2, bx = 0.0, by = 0.0
                for yy in -4...4 { for xx in -4...4 {
                    let sc = score(Double(xx) * 0.5, Double(yy) * 0.5)
                    if sc > best { best = sc; bx = Double(xx) * 0.5; by = Double(yy) * 0.5 }
                } }
                let cx = bx, cy = by
                for yy in -4...4 { for xx in -4...4 {
                    let ox = cx + Double(xx) * 0.125, oy = cy + Double(yy) * 0.125
                    let sc = score(ox, oy)
                    if sc > best { best = sc; bx = ox; by = oy }
                } }
                if best > 0.5 && abs(bx) < 2.2 && abs(by) < 2.2 {
                    rp[q] = (J.0 * bx + J.1 * by, J.2 * bx + J.3 * by, true)
                }
            }
            if concurrent { DispatchQueue.concurrentPerform(iterations: idx.count, execute: work) }
            else { for q in 0..<idx.count { work(q) } }
        }
        for (q, a) in idx.enumerated() where res[q].2 {
            dx[a] = res[q].0; dy[a] = res[q].1; valid[a] = true
            stats.markersFound += 1
        }
        // outlier rejection against neighbour median-ish average
        let measured = valid
        var reject: [Int] = []
        for a in idx where measured[a] {
            let i = a % lw, j = a / lw
            var sx = 0.0, sy = 0.0, k = 0.0
            for (ni, nj) in [(i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1)] where ni >= 0 && nj >= 0 && ni < lw && nj < lh {
                let b = nj * lw + ni
                if measured[b] { sx += dx[b]; sy += dy[b]; k += 1 }
            }
            if k >= 2 && hypot(dx[a] - sx / k, dy[a] - sy / k) > 0.8 * cellPx { reject.append(a) }
        }
        for a in reject { valid[a] = false; dx[a] = 0; dy[a] = 0; stats.markersFound -= 1 }
        // fill holes by diffusion from valid neighbours
        for _ in 0..<(lw + lh) {
            var changed = false
            let v0 = valid
            for a in 0..<(lw * lh) where !v0[a] {
                let i = a % lw, j = a / lw
                var sx = 0.0, sy = 0.0, k = 0.0
                for (ni, nj) in [(i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1)] where ni >= 0 && nj >= 0 && ni < lw && nj < lh {
                    let b = nj * lw + ni
                    if v0[b] { sx += dx[b]; sy += dy[b]; k += 1 }
                }
                if k > 0 { dx[a] = sx / k; dy[a] = sy / k; valid[a] = true; changed = true }
            }
            if !changed { break }
        }
        return (dx, dy)
    }

    // MARK: classification

    private func normalise(_ v: inout [Float], _ L: FrameLayout, _ C: Int) {
        let W = L.cols, Hh = L.rows
        let IW = W + 1
        let R = 6
        var cnt = [Float](repeating: 0, count: IW * (Hh + 1))
        var s1 = [Float](repeating: 0, count: IW * (Hh + 1) * C)
        var s2 = [Float](repeating: 0, count: IW * (Hh + 1) * C)
        let isData = L.kind.map { $0 == .data }
        for y in 0..<Hh {
            var rc: Float = 0
            var r1 = [Float](repeating: 0, count: C), r2 = [Float](repeating: 0, count: C)
            for x in 0..<W {
                let c = y * W + x
                if isData[c] {
                    rc += 1
                    for ch in 0..<C { let a = v[c * C + ch]; r1[ch] += a; r2[ch] += a * a }
                }
                let o = (y + 1) * IW + x + 1, u = y * IW + x + 1
                cnt[o] = cnt[u] + rc
                for ch in 0..<C {
                    s1[o * C + ch] = s1[u * C + ch] + r1[ch]
                    s2[o * C + ch] = s2[u * C + ch] + r2[ch]
                }
            }
        }
        for c in L.dataCells {
            let ci = Int(c)
            let x = ci % W, y = ci / W
            let x0 = max(0, x - R), x1 = min(W, x + R + 1), y0 = max(0, y - R), y1 = min(Hh, y + R + 1)
            let a = y1 * IW + x1, b = y0 * IW + x0, cc = y0 * IW + x1, d = y1 * IW + x0
            let n = cnt[a] + cnt[b] - cnt[cc] - cnt[d]
            if n < 4 { continue }
            for ch in 0..<C {
                let m = (s1[a * C + ch] + s1[b * C + ch] - s1[cc * C + ch] - s1[d * C + ch]) / n
                let q = (s2[a * C + ch] + s2[b * C + ch] - s2[cc * C + ch] - s2[d * C + ch]) / n
                let sd = sqrt(max(q - m * m, 1))
                v[ci * C + ch] = (v[ci * C + ch] - m) / sd
            }
        }
    }

    /// Fits y ≈ a·s + b·Σ₄ s_nbr + c·Σ_diag s_nbr per channel on hard decisions, then removes the
    /// neighbour terms. Two passes so improved decisions refine the estimate.
    private func equalise(_ v: inout [Float], _ L: FrameLayout, _ C: Int) {
        let W = L.cols, H = L.rows
        let isData = L.kind.map { $0 == .data }
        let cells = L.dataCells
        for _ in 0..<2 {
            var sgn = [Float](repeating: 0, count: W * H * C)
            for c in cells { let ci = Int(c); for ch in 0..<C { sgn[ci * C + ch] = v[ci * C + ch] > 0 ? 1 : -1 } }
            var n4 = [Float](repeating: 0, count: cells.count * C)
            var nd = [Float](repeating: 0, count: cells.count * C)
            for (k, c) in cells.enumerated() {
                let ci = Int(c), x = ci % W, y = ci / W
                for ch in 0..<C {
                    var a: Float = 0, d: Float = 0
                    if x > 0 && isData[ci - 1] { a += sgn[(ci - 1) * C + ch] }
                    if x < W - 1 && isData[ci + 1] { a += sgn[(ci + 1) * C + ch] }
                    if y > 0 && isData[ci - W] { a += sgn[(ci - W) * C + ch] }
                    if y < H - 1 && isData[ci + W] { a += sgn[(ci + W) * C + ch] }
                    if x > 0 && y > 0 && isData[ci - W - 1] { d += sgn[(ci - W - 1) * C + ch] }
                    if x < W - 1 && y > 0 && isData[ci - W + 1] { d += sgn[(ci - W + 1) * C + ch] }
                    if x > 0 && y < H - 1 && isData[ci + W - 1] { d += sgn[(ci + W - 1) * C + ch] }
                    if x < W - 1 && y < H - 1 && isData[ci + W + 1] { d += sgn[(ci + W + 1) * C + ch] }
                    n4[k * C + ch] = a; nd[k * C + ch] = d
                }
            }
            for ch in 0..<C {
                // normal equations for [s, n4, nd]
                var M = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 3)
                for (k, c) in cells.enumerated() {
                    let ci = Int(c)
                    let f = [Double(sgn[ci * C + ch]), Double(n4[k * C + ch]), Double(nd[k * C + ch])]
                    let y = Double(v[ci * C + ch])
                    for i in 0..<3 { for j in 0..<3 { M[i][j] += f[i] * f[j] }; M[i][3] += f[i] * y }
                }
                guard let sol = solve(&M, 3), sol[0] > 0.05 else { continue }
                let b = Float(sol[1]), cd = Float(sol[2]), a = Float(sol[0])
                if abs(b) < 0.01 && abs(cd) < 0.01 { continue }
                for (k, c) in cells.enumerated() {
                    let i = Int(c) * C + ch
                    v[i] = (v[i] - b * n4[k * C + ch] - cd * nd[k * C + ch]) / a
                }
            }
        }
    }

    private func decorrelate(_ v: inout [Float], _ L: FrameLayout, _ C: Int) {
        for _ in 0..<2 {
            var A = [Double](repeating: 0, count: C * C)
            var n = 0.0
            for c in L.dataCells {
                let ci = Int(c) * C
                for a in 0..<C {
                    for b in 0..<C {
                        A[a * C + b] += Double(v[ci + a]) * (v[ci + b] > 0 ? 1 : -1)
                    }
                }
                n += 1
            }
            if n == 0 { return }
            A = A.map { $0 / n }
            var inv: [Double]
            if C == 2 {
                let det = A[0] * A[3] - A[1] * A[2]
                if abs(det) < 1e-6 { return }
                inv = [A[3] / det, -A[1] / det, -A[2] / det, A[0] / det]
            } else {
                guard let i3 = invert3(A) else { return }
                inv = i3
            }
            // already near identity: skip
            var off = 0.0
            for a in 0..<C { for b in 0..<C where a != b { off += abs(A[a * C + b]) } }
            if off < 0.02 { return }
            let fi = inv.map { Float($0) }
            var tmp = [Float](repeating: 0, count: C)
            for c in L.dataCells {
                let ci = Int(c) * C
                for a in 0..<C {
                    var s: Float = 0
                    for b in 0..<C { s += fi[a * C + b] * v[ci + b] }
                    tmp[a] = s
                }
                for a in 0..<C { v[ci + a] = tmp[a] }
            }
        }
    }
}
