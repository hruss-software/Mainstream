import Foundation

struct FinderCandidate {
    var x: Double
    var y: Double
    var module: Double
    var count: Int
}

/// QR-style 1:1:3:1:1 finder detection on a small luma image.
final class FinderDetector {
    let w: Int
    let h: Int
    var lum: [UInt8]
    private var bin: [UInt8]
    private var integral: [UInt32]

    init(w: Int, h: Int) {
        self.w = w
        self.h = h
        lum = [UInt8](repeating: 0, count: w * h)
        bin = [UInt8](repeating: 0, count: w * h)
        integral = [UInt32](repeating: 0, count: (w + 1) * (h + 1))
    }

    func binarize() {
        let W = w + 1
        lum.withUnsafeBufferPointer { L in
            integral.withUnsafeMutableBufferPointer { I in
                for y in 0..<h {
                    var row: UInt32 = 0
                    for x in 0..<w {
                        row += UInt32(L[y * w + x])
                        I[(y + 1) * W + x + 1] = I[y * W + x + 1] + row
                    }
                }
                let r = max(6, min(w, h) / 14)
                bin.withUnsafeMutableBufferPointer { B in
                    for y in 0..<h {
                        let y0 = max(0, y - r), y1 = min(h, y + r + 1)
                        for x in 0..<w {
                            let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                            let s = I[y1 * W + x1] + I[y0 * W + x0] - I[y0 * W + x1] - I[y1 * W + x0]
                            let area = UInt32((y1 - y0) * (x1 - x0))
                            let v = UInt32(L[y * w + x])
                            // dark if below 92% of local mean
                            B[y * w + x] = v * area * 100 < s * 92 ? 1 : 0
                        }
                    }
                }
            }
        }
    }

    @inline(__always) private func ratioOK(_ c: [Int]) -> Bool {
        let total = c[0] + c[1] + c[2] + c[3] + c[4]
        if total < 7 || c.contains(0) { return false }
        let m = Double(total) / 7
        let v = m * 0.6
        return abs(m - Double(c[0])) < v && abs(m - Double(c[1])) < v && abs(3 * m - Double(c[2])) < 3 * v
            && abs(m - Double(c[3])) < v && abs(m - Double(c[4])) < v
    }

    @inline(__always) private func px(_ x: Int, _ y: Int) -> Bool { bin[y * w + x] == 1 }

    /// Cross-check along a direction through (cx, cy); returns refined centre offset and total.
    private func crossCheck(_ cx: Int, _ cy: Int, dx: Int, dy: Int, maxCount: Int, expectedTotal: Int) -> (Double, Int)? {
        var c = [0, 0, 0, 0, 0]
        func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h }
        var x = cx, y = cy
        // backwards
        while inside(x, y) && px(x, y) { c[2] += 1; x -= dx; y -= dy }
        if !inside(x, y) { return nil }
        while inside(x, y) && !px(x, y) && c[1] <= maxCount { c[1] += 1; x -= dx; y -= dy }
        if !inside(x, y) || c[1] > maxCount { return nil }
        while inside(x, y) && px(x, y) && c[0] <= maxCount { c[0] += 1; x -= dx; y -= dy }
        if c[0] > maxCount { return nil }
        x = cx + dx; y = cy + dy
        while inside(x, y) && px(x, y) { c[2] += 1; x += dx; y += dy }
        if !inside(x, y) { return nil }
        while inside(x, y) && !px(x, y) && c[3] <= maxCount { c[3] += 1; x += dx; y += dy }
        if !inside(x, y) || c[3] > maxCount { return nil }
        while inside(x, y) && px(x, y) && c[4] <= maxCount { c[4] += 1; x += dx; y += dy }
        if c[4] > maxCount { return nil }
        let total = c.reduce(0, +)
        if 5 * abs(total - expectedTotal) >= 2 * expectedTotal { return nil }
        guard ratioOK(c) else { return nil }
        // centre along direction, relative to (cx,cy): end - c4 - c3 - c2/2
        let endOffset = Double(x * dx + y * dy - (cx * dx + cy * dy))
        let centre = endOffset - Double(c[4] + c[3]) - Double(c[2]) / 2
        return (centre, total)
    }

    func detect() -> [FinderCandidate] {
        binarize()
        var cands: [FinderCandidate] = []
        for y in stride(from: 0, to: h, by: 2) {
            var c = [0, 0, 0, 0, 0]
            var state = 0
            var x = 0
            while x <= w {
                let black = x < w ? px(x, y) : false
                if black {
                    if state & 1 == 1 { state += 1 }
                    c[state] += 1
                } else {
                    if state & 1 == 0 {
                        if state == 4 {
                            if ratioOK(c) { handle(c, x, y, &cands) }
                            c = [c[2], c[3], c[4], 1, 0]
                            state = 3
                        } else {
                            state += 1
                            c[state] += 1
                        }
                    } else {
                        c[state] += 1
                    }
                }
                x += 1
            }
        }
        return cands
    }

    private func handle(_ c: [Int], _ end: Int, _ y: Int, _ cands: inout [FinderCandidate]) {
        let total = c.reduce(0, +)
        let cx = Double(end) - Double(c[4] + c[3]) - Double(c[2]) / 2
        let icx = Int(cx)
        guard icx >= 0 && icx < w else { return }
        guard let (vy, vt) = crossCheck(icx, y, dx: 0, dy: 1, maxCount: c[2], expectedTotal: total) else { return }
        let cy = Double(y) + vy
        let icy = Int(cy)
        guard icy >= 0 && icy < h else { return }
        guard let (hx, ht) = crossCheck(icx, icy, dx: 1, dy: 0, maxCount: c[2], expectedTotal: total) else { return }
        let fx = Double(icx) + hx
        let ifx = Int(fx)
        guard ifx >= 0 && ifx < w else { return }
        guard crossCheck(ifx, icy, dx: 1, dy: 1, maxCount: c[2] * 2, expectedTotal: (ht + vt) / 2) != nil
            || crossCheck(ifx, icy, dx: 1, dy: -1, maxCount: c[2] * 2, expectedTotal: (ht + vt) / 2) != nil
        else { return }
        let module = Double(ht + vt) / 14
        for i in cands.indices {
            let d = cands[i]
            if abs(d.x - fx) <= module * 1.5 && abs(d.y - cy) <= module * 1.5 && abs(d.module - module) <= max(1, d.module * 0.5) {
                let n = Double(d.count)
                cands[i].x = (d.x * n + fx) / (n + 1)
                cands[i].y = (d.y * n + cy) / (n + 1)
                cands[i].module = (d.module * n + module) / (n + 1)
                cands[i].count += 1
                return
            }
        }
        cands.append(FinderCandidate(x: fx, y: cy, module: module, count: 1))
    }

    /// Picks four candidates forming a convex quad; returns them clockwise (image coords).
    static func selectQuad(_ all: [FinderCandidate]) -> [FinderCandidate]? {
        let c = all.filter { $0.count >= 2 }.sorted { $0.count > $1.count }.prefix(10)
        let a = Array(c)
        guard a.count >= 4 else { return nil }
        var best: [FinderCandidate]? = nil
        var bestScore = -1.0
        for i in 0..<a.count { for j in (i + 1)..<a.count { for k in (j + 1)..<a.count { for l in (k + 1)..<a.count {
            let q = [a[i], a[j], a[k], a[l]]
            let ms = q.map { $0.module }
            guard let mn = ms.min(), let mx = ms.max(), mx < mn * 1.7 else { continue }
            guard let ordered = clockwise(q) else { continue }
            let avgM = ms.reduce(0, +) / 4
            var okSides = true
            for t in 0..<4 {
                let p = ordered[t], r = ordered[(t + 1) % 4]
                if hypot(p.x - r.x, p.y - r.y) < avgM * 12 { okSides = false }
            }
            guard okSides else { continue }
            let score = Double(q.reduce(0) { $0 + $1.count }) - Double(mx / mn - 1) * 10
            if score > bestScore { bestScore = score; best = ordered }
        } } } }
        return best
    }

    static func clockwise(_ q: [FinderCandidate]) -> [FinderCandidate]? {
        let cx = q.reduce(0) { $0 + $1.x } / 4, cy = q.reduce(0) { $0 + $1.y } / 4
        let s = q.sorted { atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx) }
        var sign = 0.0
        for t in 0..<4 {
            let a = s[t], b = s[(t + 1) % 4], c = s[(t + 2) % 4]
            let cr = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if sign == 0 { sign = cr } else if (cr > 0) != (sign > 0) { return nil }
            if abs(cr) < 1e-6 { return nil }
        }
        return s
    }
}
