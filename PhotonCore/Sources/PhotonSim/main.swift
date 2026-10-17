import Foundation
import PhotonCore
import CoreGraphics
import ImageIO

// Sweeps the rate ladder over synthetic channel conditions and reports goodput.
// usage: PhotonSim [camW camH] [frames]

let args = CommandLine.arguments
let camW = args.count > 2 ? Int(args[1])! : 3840
let camH = args.count > 2 ? Int(args[2])! : 2160
let framesPer = args.count > 3 ? Int(args[3])! : 6
let screenW = 1206, screenH = 2622           // iPhone 17 Pro, px
let availW = screenW - 2 * 30, availH = screenH - 3 * 150

struct Cond { let name: String; let blur: Double; let noise: Double; let fill: Double; let ct: Double; let tilt: Double }
let conds = [
    Cond(name: "good", blur: 1.2, noise: 3, fill: 0.85, ct: 0.10, tilt: 0.03),
    Cond(name: "soft", blur: 2.0, noise: 4, fill: 0.85, ct: 0.15, tilt: 0.05),
    Cond(name: "far ", blur: 1.4, noise: 4, fill: 0.55, ct: 0.12, tilt: 0.04),
    Cond(name: "bad ", blur: 2.8, noise: 7, fill: 0.70, ct: 0.20, tilt: 0.07),
]

var rng = SystemRandomNumberGenerator()
let payload = Payload(kind: .file, name: "r.bin", data: Data((0..<2_000_000).map { _ in UInt8.random(in: 0...255, using: &rng) }))
let levelFilter: Set<Int>? = ProcessInfo.processInfo.environment["LEVELS"].map { Set($0.split(separator: ",").map { Int($0)! }) }

let env = ProcessInfo.processInfo.environment

// Decode a screenshot of the sender: directly, and through the synthetic camera.
if let path = env["DECODE"] {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let src = CGImageSourceCreateWithURL(url, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("load") }
    var shot = RGBAImage(width: cg.width, height: cg.height)
    let ctx = CGContext(data: &shot.pixels, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    var bgra = shot.pixels
    for i in stride(from: 0, to: bgra.count, by: 4) { bgra.swapAt(i, i + 2) }
    let fd = FrameDecoder()
    let (pk, st) = bgra.withUnsafeBufferPointer { fd.decode(BGRAFrame(base: $0.baseAddress!, width: shot.width, height: shot.height, bytesPerRow: shot.width * 4)) }
    print("direct: found \(st.found) level \(String(describing: st.levelIndex)) decoded \(st.decoded)/\(st.slots) corr \(st.corrections) markers \(st.markersFound)/\(st.markersTotal)")
    let td = TransferDecoder()
    for q in pk { td.ingest(q) }
    if let r = td.takeResult() { print("payload:", String(decoding: r.data, as: UTF8.self)) }
    for (i, c) in conds.enumerated() {
        var p = ChannelParams()
        p.camW = camW; p.camH = camH
        p.blur = c.blur * Double(camW) / 3840; p.noise = c.noise; p.fill = c.fill; p.crosstalk = c.ct; p.tilt = c.tilt
        p.seed = UInt64(i + 5)
        let cam = Channel.capture(shot, p)
        let (_, s2) = cam.withUnsafeBufferPointer { fd.decode(BGRAFrame(base: $0.baseAddress!, width: camW, height: camH, bytesPerRow: camW * 4)) }
        print("camera \(c.name): found \(s2.found) decoded \(s2.decoded)/\(s2.slots) corr \(s2.corrections)")
    }
    exit(0)
}
if env["TEMPORAL"] != nil {
    let levels = (env["LEVELS"] ?? "6,8,10,12").split(separator: ",").map { Int($0)! }
    let holds = (env["HOLDS"] ?? "1,2,3,4").split(separator: ",").map { Int($0)! }
    let procs = (env["PROC"] ?? "60,30").split(separator: ",").map { Double($0)! }
    let c = conds[Int(env["COND"] ?? "0")!]
    let dur = Double(env["DUR"] ?? "0.5")!
    print("temporal: cond \(c.name) camera \(camW)x\(camH) duration \(dur)s readout 12ms exposure 4ms")
    for li in levels { for pf in procs { for h in holds {
        let (g, pc) = temporal(level: li, hold: h, procFps: pf, cond: c, duration: dur, readout: 0.012, exposure: 0.004, seed: UInt64(li * 100 + h))
        print(String(format: "L%2d proc %2.0f fps hold %d (%4.1f fps) | unique goodput %6.1f kB/s  per-capture ok %5.1f%%", li, pf, h, 60.0 / Double(h), g / 1000, pc * 100))
    } } }
    exit(0)
}

print("camera \(camW)x\(camH), \(framesPer) frames per point")
for c in conds {
    print("== \(c.name)  blur \(c.blur) noise \(c.noise) fill \(c.fill) crosstalk \(c.ct)")
    var bestRate = 0.0, bestLevel = -1
    for li in 0..<Ladder.levels.count {
        if let f = levelFilter, !f.contains(li) { continue }
        guard let fit = Ladder.fit(level: li, width: availW, height: availH) else { continue }
        let L = FrameLayout.get(level: li, aspect: fit.aspect)
        let enc = TransferEncoder(payload: payload)
        let fd = FrameDecoder()
        var dec = 0, tot = 0, corr = 0, found = 0
        var tDec = 0.0
        for fi in 0..<framesPer {
            let fr = Renderer.frame(enc, layout: L)
            let scr = Channel.screen(layout: L, frame: fr, cellPx: fit.cellPx, screenW: screenW, screenH: screenH)
            var p = ChannelParams()
            p.camW = camW; p.camH = camH
            p.blur = c.blur * Double(camW) / 3840; p.noise = c.noise; p.fill = c.fill; p.crosstalk = c.ct; p.tilt = c.tilt
            p.seed = UInt64(fi * 31 + li + 1)
            p.rotation = Double(fi % 3 - 1) * 0.05
            let cam = Channel.capture(scr, p)
            let t0 = Date()
            let (pk, st) = cam.withUnsafeBufferPointer {
                fd.decode(BGRAFrame(base: $0.baseAddress!, width: camW, height: camH, bytesPerRow: camW * 4))
            }
            tDec += Date().timeIntervalSince(t0)
            if st.found { found += 1 }
            dec += pk.count; tot += L.slots; corr += st.corrections
        }
        let q = Double(dec) / Double(tot)
        let rate = q * L.nominalRate
        if rate > bestRate { bestRate = rate; bestLevel = li }
        let lv = L.level
        print(String(format: "L%2d %3dx%3d k%2d bpc%d par%2d hold%d | found %d/%d  ok %5.1f%%  corr/cw %5.2f  goodput %6.1f kB/s  decode %4.0f ms",
                     li, L.cols, L.rows, fit.cellPx, lv.bpc, lv.parity, lv.hold, found, framesPer, q * 100,
                     dec > 0 ? Double(corr) / Double(dec) : 0, rate / 1000, tDec / Double(framesPer) * 1000))
    }
    print("best: L\(bestLevel) \(Int(bestRate / 1000)) kB/s")
}

// MARK: temporal model — display scan-out + rolling shutter + exposure blending

func temporal(level li: Int, hold: Int, procFps: Double, cond c: Cond, duration: Double, readout: Double, exposure: Double, seed: UInt64) -> (goodput: Double, perCapture: Double) {
    guard let fit = Ladder.fit(level: li, width: availW, height: availH) else { return (0, 0) }
    let L = FrameLayout.get(level: li, aspect: fit.aspect)
    let enc = TransferEncoder(payload: payload)
    let fd = FrameDecoder()
    var screens: [RGBAImage] = []
    func screen(_ k: Int) -> RGBAImage {
        while screens.count <= k {
            let fr = Renderer.frame(enc, layout: L)
            screens.append(Channel.screen(layout: L, frame: fr, cellPx: fit.cellPx, screenW: screenW, screenH: screenH))
        }
        return screens[k]
    }
    let T = 1.0 / 60, HT = Double(hold) * T
    var r = SplitMix64Sim(seed)
    let phase = r.unit() / procFps
    var seen = Set<Int>()
    var t = phase + T   // start after first frame fully drawn
    var captures = 0, decodedSum = 0
    while t < duration + T {
        let kmin = max(0, Int(floor((t - T) / HT)))
        let kmax = Int(floor((t + readout + exposure) / HT)) + 1
        let t0 = Date()
        let frames = (kmin...kmax).map { screen($0) }
        let t1 = Date()
        var p = ChannelParams()
        p.camW = camW; p.camH = camH
        p.blur = c.blur * Double(camW) / 3840; p.noise = c.noise; p.fill = c.fill; p.crosstalk = c.ct; p.tilt = c.tilt
        p.seed = seed &+ UInt64(captures)
        let H = Double(camH), tt = t
        let cam = Channel.capture(frames: frames, p) { ys, yc in
            let a = tt + Double(yc) / H * readout
            let k = Int(floor((a - ys * T) / HT))
            let s = Double(k + 1) * HT + ys * T
            let w = Float(max(0, min(1, (a + exposure - s) / exposure)))
            return (k - kmin, w)
        }
        let t2 = Date()
        let (pk, _) = cam.withUnsafeBufferPointer {
            fd.decode(BGRAFrame(base: $0.baseAddress!, width: camW, height: camH, bytesPerRow: camW * 4))
        }
        if env["PROFILE"] != nil { print(String(format: "render %.2fs capture %.2fs decode %.3fs", t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), Date().timeIntervalSince(t2))) }
        for q in pk where q.type == .data { seen.insert(q.block << 16 | q.id) }
        decodedSum += pk.count
        captures += 1
        t += 1 / procFps
    }
    return (Double(seen.count) * Double(Wire.symbolSize) / duration, Double(decodedSum) / Double(max(1, captures)) / Double(L.slots))
}

struct SplitMix64Sim {
    var s: UInt64
    init(_ s: UInt64) { self.s = s }
    mutating func unit() -> Double {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
