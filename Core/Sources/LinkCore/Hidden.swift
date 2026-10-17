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

public final class HiddenDemodulator {
    public let window: Int
    public private(set) var width = 0
    public private(set) var height = 0
    private var factor = 1
    private var ring: [[Int16]] = []
    private var S: [Int32] = []
    private var cur: [Int16] = []
    private var out: [UInt8] = []
    private var count = 0
    private var lastTime: Double? = nil

    public init(window: Int = Hidden.window) {
        precondition(window % 2 == 0)
        self.window = window
    }

    public func reset() {
        count = 0
        lastTime = nil
        for i in ring.indices { for j in ring[i].indices { ring[i][j] = 0 } }
        for i in S.indices { S[i] = 0 }
    }

    /// Pushes a capture; returns true once a full window has been accumulated.
    @discardableResult
    public func push(_ f: BGRAFrame, time: Double, frameInterval: Double = 1.0 / 60) -> Bool {
        let fct = max(1, max(f.width, f.height) / 1280)
        let w = f.width / fct, h = f.height / fct
        if w != width || h != height || fct != factor {
            width = w; height = h; factor = fct
            ring = [[Int16]](repeating: [Int16](repeating: 0, count: w * h * 3), count: window)
            S = [Int32](repeating: 0, count: w * h * 3)
            cur = [Int16](repeating: 0, count: w * h * 3)
            out = [UInt8](repeating: 255, count: w * h * 4)
            reset()
        }
        if let lt = lastTime, time - lt > frameInterval * 1.6 { reset() }
        lastTime = time
        let half = fct / 2
        // 1. downsample (2×2 average per sample) into `cur`
        cur.withUnsafeMutableBufferPointer { C in
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
        // 2. S_t = C_t − S_{t−1} − C_{t−W}
        let slot = count % window
        ring[slot].withUnsafeMutableBufferPointer { R in
            S.withUnsafeMutableBufferPointer { Sp in
                cur.withUnsafeBufferPointer { Cp in
                    let rp = R.baseAddress!, sp = Sp.baseAddress!, cp = Cp.baseAddress!
                    let n = w * h * 3
                    let chunk = (n + 15) / 16
                    DispatchQueue.concurrentPerform(iterations: 16) { k in
                        for i in (k * chunk)..<min(n, (k + 1) * chunk) {
                            sp[i] = Int32(cp[i]) - sp[i] - Int32(rp[i])
                            rp[i] = cp[i]
                        }
                    }
                }
            }
        }
        count += 1
        return count >= window
    }

    /// Renders the demodulated signal as a BGRA image centred on 128 and decodes it with `body`.
    public func withFrame<R>(_ body: (BGRAFrame) -> R) -> R {
        let src = S
        var hist = [Int](repeating: 0, count: 1024)
        var n = 0
        src.withUnsafeBufferPointer { sp in
            var i = 0
            while i < sp.count { hist[min(1023, Int(abs(sp[i])))] += 1; n += 1; i += 3 * 7 }
        }
        var acc = 0, med = 1
        for (v, c) in hist.enumerated() { acc += c; if acc * 2 >= n { med = max(1, v); break } }
        let gain = Float(48) / Float(med)
        let w = width, h = height
        src.withUnsafeBufferPointer { sp in
            out.withUnsafeMutableBufferPointer { op in
                let s = sp.baseAddress!, o = op.baseAddress!
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let i = (y * w + x) * 3, d = (y * w + x) * 4
                        o[d] = UInt8(max(0, min(255, 128 + Float(s[i + 2]) * gain)))
                        o[d + 1] = UInt8(max(0, min(255, 128 + Float(s[i + 1]) * gain)))
                        o[d + 2] = UInt8(max(0, min(255, 128 + Float(s[i]) * gain)))
                    }
                }
            }
        }
        return out.withUnsafeBufferPointer { body(BGRAFrame(base: $0.baseAddress!, width: w, height: h, bytesPerRow: w * 4)) }
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
