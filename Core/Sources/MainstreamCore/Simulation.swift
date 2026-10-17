import Foundation

/// Synthetic screen→camera channel used for tests and rate tuning.
public struct ChannelParams {
    public var camW = 1920
    public var camH = 1080
    public var fill = 0.8            // screen long side as a fraction of camera width
    public var rotation = 0.03       // radians, added to a 90° turn
    public var tilt = 0.04           // perspective corner jitter (fraction of size)
    public var blur = 0.8            // Gaussian sigma in camera px
    public var noise = 3.0           // additive sigma (0–255)
    public var crosstalk = 0.12      // off-diagonal colour mixing
    public var vignette = 0.25
    public var pixelFill = 0.7       // lit fraction of each screen pixel (moiré)
    public var gain = 0.85
    public var seed: UInt64 = 1
    /// Seed for placement; nil uses `seed`. Fixed across captures for a steady camera.
    public var geometrySeed: UInt64? = nil
    /// Per-capture hand shake in camera px.
    public var shake = 0.0
    public var offset = (0.0, 0.0)
    public init() {}
}

public enum Channel {
    /// Lays the code out on a white phone screen of `screenW × screenH` px.
    public static func screen(layout L: FrameLayout, frame: RGBAImage, cellPx k: Int, screenW: Int, screenH: Int) -> RGBAImage {
        let code = Renderer.composite(layout: L, frame: frame, cellPx: k)
        var s = RGBAImage(width: screenW, height: screenH)
        let ox = (screenW - code.width) / 2, oy = (screenH - code.height) / 2
        for y in 0..<code.height {
            let si = y * code.width * 4
            let di = ((y + oy) * screenW + ox) * 4
            for x in 0..<(code.width * 4) { s.pixels[di + x] = code.pixels[si + x] }
        }
        return s
    }

    /// Returns a BGRA camera image of the screen.
    public static func capture(_ screen: RGBAImage, _ p: ChannelParams) -> [UInt8] {
        capture(frames: [screen], p, mix: nil)
    }

    /// Each pixel shows frames[i]·(1-w) + frames[i+1]·w where (i, w) = mix(screenY01, cameraRow).
    public static func capture(frames: [RGBAImage], _ p: ChannelParams, mix: ((Double, Int) -> (Int, Float))?) -> [UInt8] {
        let screen = frames[0]
        var rng = SplitMix64(p.geometrySeed ?? p.seed)
        func rnd() -> Double { Double(rng.next() >> 11) / Double(1 << 53) * 2 - 1 }
        var srng = SplitMix64(p.seed &* 31 &+ 7)
        let shakeX = (Double(srng.next() >> 11) / Double(1 << 53) * 2 - 1) * p.shake
        let shakeY = (Double(srng.next() >> 11) / Double(1 << 53) * 2 - 1) * p.shake
        let W = p.camW, H = p.camH
        let sw = Double(screen.width), sh = Double(screen.height)
        // screen rotated ~90° so its long side runs along camera x
        let scale = p.fill * Double(W) / sh
        let cx = Double(W) / 2 + rnd() * 0.03 * Double(W), cy = Double(H) / 2 + rnd() * 0.03 * Double(H)
        let ang = Double.pi / 2 + p.rotation
        let ca = cos(ang), sa = sin(ang)
        var dst: [Pt] = []
        for (u, v) in [(0.0, 0.0), (sw, 0.0), (sw, sh), (0.0, sh)] {
            let x = (u - sw / 2) * scale, y = (v - sh / 2) * scale
            var X = cx + x * ca - y * sa + shakeX + p.offset.0, Y = cy + x * sa + y * ca + shakeY + p.offset.1
            X += rnd() * p.tilt * sw * scale; Y += rnd() * p.tilt * sw * scale
            dst.append(Pt(X, Y))
        }
        let src = [Pt(0, 0), Pt(sw, 0), Pt(sw, sh), Pt(0, sh)]
        let Hinv = Homography.from(dst, src)!
        var img = [Float](repeating: 0, count: W * H * 3)
        let ss = 3
        let pf = p.pixelFill
        let lo = (1 - sqrt(pf)) / 2, hi = 1 - lo
        let fsz = screen.pixels.count
        var all = [UInt8]()
        all.reserveCapacity(fsz * frames.count)
        for f in frames { all += f.pixels }
        let nf = frames.count
        // tabulate mix(screenY, row) to avoid calling a shared closure from many threads
        let bins = 1024
        var mixF = [Int32](repeating: 0, count: mix == nil ? 0 : H * bins)
        var mixW = [Float](repeating: 0, count: mix == nil ? 0 : H * bins)
        if let mix {
            for y in 0..<H { for b in 0..<bins {
                let (i, w) = mix((Double(b) + 0.5) / Double(bins), y)
                mixF[y * bins + b] = Int32(max(0, min(nf - 1, i))); mixW[y * bins + b] = w
            } }
        }
        let hasMix = mix != nil
        img.withUnsafeMutableBufferPointer { I in
            let ip = I.baseAddress!
            all.withUnsafeBufferPointer { AB in
            let ap = AB.baseAddress!
            DispatchQueue.concurrentPerform(iterations: H) { y in
                do {
                    for x in 0..<W {
                        var r: Float = 0, g: Float = 0, b: Float = 0
                        for sy in 0..<ss { for sx in 0..<ss {
                            let q = Hinv.apply(Double(x) + (Double(sx) + 0.5) / Double(ss), Double(y) + (Double(sy) + 0.5) / Double(ss))
                            if q.x < 0 || q.y < 0 || q.x >= sw || q.y >= sh { r += 12; g += 12; b += 12; continue }
                            let fx = q.x - floor(q.x), fy = q.y - floor(q.y)
                            if fx < lo || fx > hi || fy < lo || fy > hi { continue }
                            let o = (Int(q.y) * screen.width + Int(q.x)) * 4
                            var fi = 0, w: Float = 0
                            if hasMix {
                                let bi = y * bins + min(bins - 1, Int(q.y / sh * Double(bins)))
                                fi = Int(mixF[bi]); w = mixW[bi]
                            }
                            let S = ap + fi * fsz
                            var sr = Float(S[o]), sg = Float(S[o + 1]), sb = Float(S[o + 2])
                            if w > 0 && fi + 1 < nf {
                                let OB = S + fsz
                                sr += (Float(OB[o]) - sr) * w; sg += (Float(OB[o + 1]) - sg) * w; sb += (Float(OB[o + 2]) - sb) * w
                            }
                            r += sr / Float(pf); g += sg / Float(pf); b += sb / Float(pf)
                        } }
                        let n = Float(ss * ss)
                        let o = (y * W + x) * 3
                        ip[o] = r / n; ip[o + 1] = g / n; ip[o + 2] = b / n
                    }
                }
            }
            }
        }
        if p.blur > 0.05 { gaussian(&img, W, H, Float(p.blur)) }
        var out = [UInt8](repeating: 255, count: W * H * 4)
        let ct = Float(p.crosstalk)
        let gain = Float(p.gain)
        let vig = Float(p.vignette)
        let noise = Float(p.noise)
        out.withUnsafeMutableBufferPointer { O in
            let op = O.baseAddress!
            img.withUnsafeBufferPointer { I in
                let ip = I.baseAddress!
                DispatchQueue.concurrentPerform(iterations: H) { y in
                    var lr = SplitMix64(p.seed &* 7919 &+ UInt64(y))
                    func gauss() -> Float {
                        let u1 = max(1e-12, Double(lr.next() >> 11) / Double(1 << 53))
                        let u2 = Double(lr.next() >> 11) / Double(1 << 53)
                        return Float(sqrt(-2 * log(u1)) * cos(2 * .pi * u2))
                    }
                    for x in 0..<W {
                        let o = (y * W + x) * 3
                        let r = ip[o], g = ip[o + 1], b = ip[o + 2]
                        let dx = Float(x) / Float(W) - 0.5, dy = Float(y) / Float(H) - 0.5
                        let v = gain * (1 - vig * (dx * dx + dy * dy) * 2)
                        var R = (r * (1 - 2 * ct) + ct * g + ct * b) * v
                        var G = (g * (1 - 2 * ct) + ct * r * 1.2 + ct * b * 0.8) * v
                        var B = (b * (1 - 2 * ct) + ct * g * 1.3 + ct * r * 0.7) * v
                        R += noise * gauss() + 6; G += noise * gauss() + 6; B += noise * gauss() + 6
                        let d = (y * W + x) * 4
                        op[d] = UInt8(max(0, min(255, B)))
                        op[d + 1] = UInt8(max(0, min(255, G)))
                        op[d + 2] = UInt8(max(0, min(255, R)))
                        op[d + 3] = 255
                    }
                }
            }
        }
        return out
    }

    static func gaussian(_ img: inout [Float], _ W: Int, _ H: Int, _ s: Float) {
        let rad = Int(ceil(s * 3))
        var k = [Float](repeating: 0, count: 2 * rad + 1)
        var sum: Float = 0
        for i in -rad...rad { k[i + rad] = exp(-Float(i * i) / (2 * s * s)); sum += k[i + rad] }
        k = k.map { $0 / sum }
        var tmp = [Float](repeating: 0, count: img.count)
        img.withUnsafeBufferPointer { I in
            tmp.withUnsafeMutableBufferPointer { T in
                let ip = I.baseAddress!, tp = T.baseAddress!
                DispatchQueue.concurrentPerform(iterations: H) { y in
                    for x in 0..<W {
                        var a: Float = 0, b: Float = 0, c: Float = 0
                        for i in -rad...rad {
                            let xx = min(W - 1, max(0, x + i))
                            let o = (y * W + xx) * 3, w = k[i + rad]
                            a += ip[o] * w; b += ip[o + 1] * w; c += ip[o + 2] * w
                        }
                        let o = (y * W + x) * 3
                        tp[o] = a; tp[o + 1] = b; tp[o + 2] = c
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { T in
            img.withUnsafeMutableBufferPointer { I in
                let ip = I.baseAddress!, tp = T.baseAddress!
                DispatchQueue.concurrentPerform(iterations: H) { y in
                    for x in 0..<W {
                        var a: Float = 0, b: Float = 0, c: Float = 0
                        for i in -rad...rad {
                            let yy = min(H - 1, max(0, y + i))
                            let o = (yy * W + x) * 3, w = k[i + rad]
                            a += tp[o] * w; b += tp[o + 1] * w; c += tp[o + 2] * w
                        }
                        let o = (y * W + x) * 3
                        ip[o] = a; ip[o + 1] = b; ip[o + 2] = c
                    }
                }
            }
        }
    }
}
