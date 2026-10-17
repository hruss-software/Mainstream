import Foundation

// Hidden video: the code layout is drawn over a video at low opacity α, alternating every
// display refresh between the pattern P and its complement 255−P. Viewers integrate the
// 60 Hz alternation into a uniform α·½ haze; a 60 fps camera recovers ±α·255 per channel
// by demodulating consecutive captures: S_t = Σ_{i<W} (−1)^i C_{t−i}.
// Each data frame is held for `window` refreshes so one window spans one symbol.

public enum Hidden {
    public static let window = 8

    /// Quiet margin around the hidden code, in pixels.
    public static func margin(layout L: FrameLayout, cellPx k: Int) -> Int { max(2, L.m) * k }

    /// Full-resolution overlay pattern: code plus a white quiet margin.
    public static func pattern(layout L: FrameLayout, frame: RGBAImage, cellPx k: Int) -> RGBAImage {
        let code = Renderer.composite(layout: L, frame: frame, cellPx: k)
        let mg = margin(layout: L, cellPx: k)
        var o = RGBAImage(width: code.width + 2 * mg, height: code.height + 2 * mg)
        code.pixels.withUnsafeBufferPointer { cp in
            o.pixels.withUnsafeMutableBufferPointer { op in
                for y in 0..<code.height {
                    let d = ((y + mg) * o.width + mg) * 4
                    (op.baseAddress! + d).update(from: cp.baseAddress! + y * code.width * 4, count: code.width * 4)
                }
            }
        }
        return o
    }

    public static func complement(_ img: RGBAImage) -> RGBAImage {
        var o = img
        o.pixels.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count { p[i] = 255 &- p[i]; p[i + 1] = 255 &- p[i + 1]; p[i + 2] = 255 &- p[i + 2]; i += 4 }
        }
        return o
    }
}

/// A demodulated hidden-code image (BGRA, mid-grey = no signal).
public struct DemodImage {
    public let width: Int
    public let height: Int
    public var bgra: [UInt8]

    public func withFrame<R>(_ body: (BGRAFrame) -> R) -> R {
        bgra.withUnsafeBufferPointer { body(BGRAFrame(base: $0.baseAddress!, width: width, height: height, bytesPerRow: width * 4)) }
    }
}

/// Recovers the hidden code from 60 fps captures. Frames are indexed by timestamp, so a
/// dropped capture only removes one term: the output is mean(even frames) − mean(odd frames)
/// over the last `window` refresh periods, which cancels the video for any mix of frames.
public final class HiddenDemodulator {
    public let window: Int
    public private(set) var width = 0
    public private(set) var height = 0
    private var factor = 1
    private var slots: [[Int16]] = []
    private var slotIndex: [Int] = []
    private var t0: Double? = nil
    private var latest: Int? = nil

    public init(window: Int = Hidden.window) {
        precondition(window % 2 == 0)
        self.window = window
    }

    public func reset() {
        t0 = nil
        latest = nil
        for i in slotIndex.indices { slotIndex[i] = Int.min }
    }

    /// Frames of each parity currently inside the window.
    private var counts: (Int, Int) {
        guard let latest else { return (0, 0) }
        var e = 0, o = 0
        for idx in slotIndex where idx != Int.min && latest - idx < window {
            if (latest - idx) & 1 == 0 { e += 1 } else { o += 1 }
        }
        return (e, o)
    }

    /// True when the window holds at least two captures of each parity.
    public var ready: Bool { let (e, o) = counts; return e >= 2 && o >= 2 }

    /// Stores a capture taken at `time` (seconds); `frameInterval` is the camera frame duration.
    public func push(_ f: BGRAFrame, time: Double, frameInterval: Double = 1.0 / 60) {
        let fct = max(1, max(f.width, f.height) / 1280)
        let w = f.width / fct, h = f.height / fct
        if w != width || h != height || fct != factor || slots.count != window {
            width = w; height = h; factor = fct
            slots = [[Int16]](repeating: [Int16](repeating: 0, count: w * h * 3), count: window)
            slotIndex = [Int](repeating: Int.min, count: window)
            reset()
        }
        if t0 == nil { t0 = time }
        let n = Int(((time - t0!) / frameInterval).rounded())
        if let l = latest {
            if n == l { return }
            // far behind the newest frame (clock jump): start over from this capture
            if n <= l - window || n < 0 { reset(); t0 = time; latest = 0; storeSlot(0, f, fct, w, h); return }
        }
        latest = max(latest ?? n, n)
        storeSlot(n, f, fct, w, h)
    }

    private func storeSlot(_ n: Int, _ f: BGRAFrame, _ fct: Int, _ w: Int, _ h: Int) {
        let slot = ((n % window) + window) % window
        slotIndex[slot] = n
        let half = fct / 2
        slots[slot].withUnsafeMutableBufferPointer { C in
            let cp = C.baseAddress!
            let bpr = f.bytesPerRow
            DispatchQueue.concurrentPerform(iterations: h) { y in
                let y0 = min(f.height - 2, y * fct + half)
                let r0 = f.base + y0 * bpr, r1 = r0 + bpr
                for x in 0..<w {
                    let x0 = min(f.width - 2, x * fct + half) * 4
                    let o = (y * w + x) * 3
                    cp[o + 2] = Int16(r0[x0]) + Int16(r0[x0 + 4]) + Int16(r1[x0]) + Int16(r1[x0 + 4])
                    cp[o + 1] = Int16(r0[x0 + 1]) + Int16(r0[x0 + 5]) + Int16(r1[x0 + 1]) + Int16(r1[x0 + 5])
                    cp[o] = Int16(r0[x0 + 2]) + Int16(r0[x0 + 6]) + Int16(r1[x0 + 2]) + Int16(r1[x0 + 6])
                }
            }
        }
    }

    /// Demodulated image of the current window, or nil until `ready`.
    public func render() -> DemodImage? {
        guard ready, let latest else { return nil }
        var plus: [Int] = [], minus: [Int] = []
        for (s, idx) in slotIndex.enumerated() where idx != Int.min && latest - idx < window {
            if (latest - idx) & 1 == 0 { plus.append(s) } else { minus.append(s) }
        }
        let w = width, h = height, n = w * h * 3
        var S = [Float](repeating: 0, count: n)
        let ip = 1 / Float(plus.count), im = 1 / Float(minus.count)
        // raw pointer tables: no Swift arrays touched inside the parallel loop
        let np = plus.count, nm = minus.count
        let tbl = UnsafeMutablePointer<UnsafePointer<Int16>>.allocate(capacity: np + nm)
        defer { tbl.deallocate() }
        withPointers(plus + minus) { all in for (k, p) in all.enumerated() { tbl[k] = p } }
        // (slots are not mutated while rendering: push and render run on the same queue)
        S.withUnsafeMutableBufferPointer { Sp in
            let sp = Sp.baseAddress!
            let chunk = (n + 63) / 64
            DispatchQueue.concurrentPerform(iterations: 64) { k in
                let lo = k * chunk, hi = min(n, (k + 1) * chunk)
                if lo >= hi { return }
                for i in lo..<hi {
                    var a: Int32 = 0, b: Int32 = 0
                    for q in 0..<np { a &+= Int32(tbl[q][i]) }
                    for q in np..<(np + nm) { b &+= Int32(tbl[q][i]) }
                    sp[i] = Float(a) * ip - Float(b) * im
                }
            }
        }
        // robust gain from the median |S| on a sparse grid
        var hist = [Int](repeating: 0, count: 1024)
        var cnt = 0
        var i = 0
        while i < n { hist[min(1023, Int(abs(S[i]) * 4))] += 1; cnt += 1; i += 3 * 7 }
        var acc = 0, med: Float = 1
        for (v, c) in hist.enumerated() { acc += c; if acc * 2 >= cnt { med = max(1, Float(v)) / 4; break } }
        let gain = 48 / med
        var out = [UInt8](repeating: 255, count: w * h * 4)
        S.withUnsafeBufferPointer { sp in
            out.withUnsafeMutableBufferPointer { op in
                let s = sp.baseAddress!, o = op.baseAddress!
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let i = (y * w + x) * 3, d = (y * w + x) * 4
                        o[d] = UInt8(max(0, min(255, 128 + s[i + 2] * gain)))
                        o[d + 1] = UInt8(max(0, min(255, 128 + s[i + 1] * gain)))
                        o[d + 2] = UInt8(max(0, min(255, 128 + s[i] * gain)))
                    }
                }
            }
        }
        return DemodImage(width: w, height: h, bgra: out)
    }

    private func withPointers<R>(_ idx: [Int], _ body: ([UnsafePointer<Int16>]) -> R) -> R {
        var ptrs: [UnsafePointer<Int16>] = []
        func rec(_ k: Int) -> R {
            if k == idx.count { return body(ptrs) }
            return slots[idx[k]].withUnsafeBufferPointer { b in ptrs.append(b.baseAddress!); return rec(k + 1) }
        }
        return rec(0)
    }
}

public enum SyntheticVideo {
    /// Moving colour content standing in for an ordinary video in tests.
    public static func frame(_ t: Double, width: Int, height: Int) -> RGBAImage {
        var img = RGBAImage(width: width, height: height)
        img.pixels.withUnsafeMutableBufferPointer { p in
            let pp = p.baseAddress!
            DispatchQueue.concurrentPerform(iterations: height) { y in
                let fy = Double(y) / Double(height)
                for x in 0..<width {
                    let fx = Double(x) / Double(width)
                    var r = 0.5 + 0.35 * sin(6 * fx + 1.3 * t) * cos(4 * fy - 0.7 * t)
                    var g = 0.45 + 0.3 * sin(9 * fy + 0.9 * t + 3 * fx)
                    var b = 0.4 + 0.3 * cos(5 * fx * fy + 1.7 * t)
                    // a moving disc and a sliding bar for sharp moving edges
                    let dx = fx - (0.5 + 0.3 * sin(t * 0.8)), dy = fy - (0.4 + 0.2 * cos(t * 0.6))
                    if dx * dx + dy * dy < 0.015 { r = 0.95; g = 0.85; b = 0.2 }
                    if abs(fy - (0.7 + 0.1 * sin(t))) < 0.03 { r = 0.1; g = 0.1; b = 0.15 }
                    // fine texture
                    let tex = 0.06 * sin(Double(x) * 0.9 + Double(y) * 0.4)
                    let o = (y * width + x) * 4
                    pp[o] = UInt8(max(0, min(255, (r + tex) * 255)))
                    pp[o + 1] = UInt8(max(0, min(255, (g + tex) * 255)))
                    pp[o + 2] = UInt8(max(0, min(255, (b + tex) * 255)))
                }
            }
        }
        return img
    }

    /// Composites `(1−α)·video + α·pattern` inside the code rectangle.
    public static func embed(_ video: RGBAImage, pattern: RGBAImage, alpha: Double) -> RGBAImage {
        var o = video
        let ox = (video.width - pattern.width) / 2, oy = (video.height - pattern.height) / 2
        let a = Float(alpha)
        o.pixels.withUnsafeMutableBufferPointer { op in
            pattern.pixels.withUnsafeBufferPointer { pp in
                for y in 0..<pattern.height {
                    for x in 0..<pattern.width {
                        let s = (y * pattern.width + x) * 4, d = ((y + oy) * video.width + x + ox) * 4
                        for c in 0..<3 { op[d + c] = UInt8(((1 - a) * Float(op[d + c]) + a * Float(pp[s + c])).rounded()) }
                    }
                }
            }
        }
        return o
    }
}
