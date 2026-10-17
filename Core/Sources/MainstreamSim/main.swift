import Foundation
import MainstreamCore
import CoreGraphics
import ImageIO

// Sweeps the rate ladder over synthetic channel conditions and reports goodput.
// usage: MainstreamSim [camW camH] [frames]

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
    Cond(name: "dfoc", blur: 4.0, noise: 5, fill: 0.80, ct: 0.15, tilt: 0.05),
    Cond(name: "blur", blur: 5.5, noise: 5, fill: 0.80, ct: 0.15, tilt: 0.05),
]
let condFilter: Set<String>? = ProcessInfo.processInfo.environment["CONDS"].map { Set($0.split(separator: ",").map(String.init)) }

var rng = SystemRandomNumberGenerator()
let payload = Payload(kind: .file, name: "r.bin", data: Data((0..<2_000_000).map { _ in UInt8.random(in: 0...255, using: &rng) }))
let levelFilter: Set<Int>? = ProcessInfo.processInfo.environment["LEVELS"].map { Set($0.split(separator: ",").map { Int($0)! }) }

let env = ProcessInfo.processInfo.environment
if let n = env["ACN"] { Acoustic.N = Int(n)! }
if let c = env["ACCP"] { Acoustic.CP = Int(c)! }
if let t = env["TSHIFT"] { Acoustic.timingShift = Int(t)! }
if env["NOPILOTROT"] != nil { Acoustic.usePilotRotation = false }
if let g = env["ACGAP"] { Acoustic.gap = Int(g)! }
if env["DEBUGPILOTS"] != nil { Acoustic.debugPilots = true }

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
    fd.bipolar = env["BIPOLAR"] != nil
    fd.debug = true
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
// Write an acoustic transmission to a WAV file, or decode a recorded one.
if let path = env["WAV"] {
    let band = AcousticBand(rawValue: Int(env["BAND"] ?? "1")!)!
    let li = Int(env["LEVEL"] ?? "\(Acoustic.defaultLevel)")!
    let bytes = Int(env["BYTES"] ?? "4000")!
    var r = SplitMix64Sim(77)
    let data = Data((0..<bytes).map { _ in UInt8(truncatingIfNeeded: Int(r.unit() * 256)) })
    try! data.write(to: URL(fileURLWithPath: path + ".payload"))
    let tx = AcousticTransmitter(encoder: TransferEncoder(payload: Payload(kind: .file, name: "w.bin", data: data)), band: band, level: li)
    var samples = [Float](repeating: 0, count: 24_000)
    while Double(samples.count) / Acoustic.sampleRate < Double(env["SECONDS"] ?? "12")! { samples += tx.nextFrame() }
    writeWAV(samples, path)
    print("wrote \(samples.count) samples, band \(band) level \(li), nominal \(Int(tx.payloadRate)) B/s")
    exit(0)
}
// Channel analysis: clock ratio from chirp positions, and echo envelope after the direct path.
if let rxPath = env["CHANNEL"] {
    let band = AcousticBand(rawValue: Int(env["BAND"] ?? "1")!)!
    let x = readWAV(rxPath)
    let c = AcousticFrame.chirpTemplate(band)
    let cn = sqrt(c.reduce(0) { $0 + $1 * $1 })
    func corr(_ at: Int) -> Float {
        guard at >= 0, at + c.count <= x.count else { return 0 }
        var a: Float = 0, e: Float = 0
        for j in 0..<c.count { let v = x[at + j]; a += v * c[j]; e += v * v }
        return a / (cn * sqrt(max(e, 1e-12)))
    }
    // coarse scan for chirps (step 8), then refine
    var peaks: [(Int, Float)] = []
    var i = 0
    while i + c.count < x.count {
        let v = corr(i)
        if v > 0.12 {
            var best = (i, v)
            for l in max(0, i - 16)...(i + 400) { let w = corr(l); if w > best.1 { best = (l, w) } }
            peaks.append(best)
            i = best.0 + 40_000
        } else { i += 8 }
    }
    print("chirps at:", peaks.map { String(format: "%d(%.2f)", $0.0, $0.1) }.joined(separator: " "))
    let F = AcousticFrame.sampleCountFor(band, Int(env["LEVEL"] ?? "2")!)
    print("expected spacing \(F) samples; observed:", zip(peaks.dropFirst(), peaks).map { $0.0 - $1.0 }.map(String.init).joined(separator: " "))
    if let p0 = peaks.first {
        // matched-filter output around the first chirp ≈ impulse response (chirp autocorrelation is narrow)
        var env: [Float] = []
        for d in stride(from: -200, to: 9600, by: 1) {
            var a: Float = 0
            let at = p0.0 + d
            if at >= 0 && at + c.count <= x.count { for j in 0..<c.count { a += x[at + j] * c[j] } }
            env.append(abs(a))
        }
        let peak = env.max() ?? 1
        var line = "echo envelope (dB re direct) by delay:"
        for (ms, w) in [(0, 0.5), (1, 1.0), (2, 1.0), (4, 2.0), (8, 4.0), (16, 8.0), (32, 16.0), (64, 32.0), (128, 64.0)] {
            let a = 200 + Int(Double(ms) * 48), b = min(env.count, a + Int(w * 48))
            let m = env[a..<b].max() ?? 0
            line += String(format: " %dms:%.0f", ms, 20 * log10(max(m, 1e-9) / peak))
        }
        print(line)
    }
    exit(0)
}
// Genie comparison: received differential phases vs the transmitted symbols, frame by frame.
if let pair = env["GENIE"] {
    let parts = pair.split(separator: ",").map(String.init)
    func frames(_ path: String) -> [AcousticStats] {
        let x = readWAV(path)
        let rx = AcousticReceiver()
        var out: [AcousticStats] = []
        var i = 0, seen = 0
        while i < x.count {
            let n = min(4800, x.count - i)
            _ = x.withUnsafeBufferPointer { rx.process(UnsafeBufferPointer(rebasing: $0[i..<(i + n)])) }
            if rx.stats.frames != seen { seen = rx.stats.frames; out.append(rx.stats) }
            i += n
        }
        return out
    }
    let tx = frames(parts[0]), rxf = frames(parts[1])
    guard let b = tx.first?.band, let li = tx.first?.level else { exit(1) }
    let K = b.carriers.count, M = 1 << Acoustic.levels[li].bits
    let unit = M == 2 ? Float.pi : 2 * Float.pi / Float(M)
    func wrap(_ a: Float) -> Float { var v = a; while v > .pi { v -= 2 * .pi }; while v < -.pi { v += 2 * .pi }; return v }
    // frames are identical every frame? no: match by symbol-decision agreement
    for (fi, r) in rxf.prefix(4).enumerated() {
        var bestT = 0, bestAgree = -1
        for (ti, t) in tx.enumerated() where t.lastIdx.count == r.lastIdx.count {
            let agree = zip(t.lastIdx, r.lastIdx).filter { $0 == $1 }.count
            if agree > bestAgree { bestAgree = agree; bestT = ti }
        }
        let t = tx[bestT]
        let total = r.lastIdx.count
        var errsRaw = [Float](), errsCorr = [Float]()
        for q in 0..<total {
            errsCorr.append(wrap(r.lastTheta[q] - Float(t.lastIdx[q]) * unit))
            errsRaw.append(wrap(r.lastRaw[q] - Float(t.lastIdx[q]) * unit))
        }
        func stats(_ e: [Float]) -> String {
            let m = e.map { abs($0) }.reduce(0, +) / Float(e.count)
            let wrong = e.filter { abs($0) > unit / 2 }.count
            return String(format: "mean|err| %.2f rad, symbol errors %.1f%%", m, 100 * Float(wrong) / Float(e.count))
        }
        print("rx frame \(fi) ↔ tx frame \(bestT): raw \(stats(errsRaw)) | after slope fit \(stats(errsCorr))")
        // per carrier-region mean error (bias) and spread, raw
        let syms = total / K
        var line = "  raw mean error by carrier decile:"
        for d in 0..<10 {
            let lo = d * K / 10, hi = (d + 1) * K / 10
            var sx: Float = 0, sy: Float = 0, sa: Float = 0, n: Float = 0
            for s in 0..<syms { for k in lo..<hi { let e = errsRaw[s * K + k]; sx += cos(e); sy += sin(e); sa += abs(e); n += 1 } }
            line += String(format: " [%.1fk bias %+.2f |e| %.2f]", Double(b.carriers.lowerBound + lo) * Acoustic.sampleRate / Double(Acoustic.N) / 1000, atan2(sy, sx), sa / n)
        }
        print(line)
    }
    exit(0)
}
if let path = env["DECODEWAV"] {
    let samples = readWAV(path)
    let rx = AcousticReceiver()
    let td = TransferDecoder()
    var frames = 0, firstDone: Double? = nil
    var i = 0
    while i < samples.count {
        let n = min(4800, samples.count - i)
        let pk = samples.withUnsafeBufferPointer { rx.process(UnsafeBufferPointer(rebasing: $0[i..<(i + n)])) }
        for p in pk { td.ingest(p) }
        if rx.stats.frames != frames {
            frames = rx.stats.frames
            print(String(format: "t %5.1fs frame %d band %@ level %@ decoded %d/%d corr %d peak %.2f progress %.0f%%", Double(i) / 48000, frames,
                         "\(rx.stats.band.map { "\($0)" } ?? "-")", "\(rx.stats.level ?? -1)", rx.stats.decoded, rx.stats.slots, rx.stats.corrections, rx.stats.lastPeak, td.progress * 100))
            if env["DIAG"] != nil, let b = rx.stats.band {
                let cq = rx.stats.carrierQuality, sq = rx.stats.symbolQuality
                let lo = b.carriers.lowerBound
                var line = "  quality by kHz:"
                var k = 0
                while k < cq.count {
                    let e = min(cq.count, k + max(1, cq.count / 10))
                    let q = cq[k..<e].reduce(0, +) / Float(e - k)
                    line += String(format: " %.1fk:%.2f", Double(lo + k) * 46.875 / 1000, q)
                    k = e
                }
                print(line)
                print("  quality by symbol:", sq.enumerated().filter { $0.offset % 4 == 0 }.map { String(format: "%.2f", $0.element) }.joined(separator: " "))
            }
        }
        if td.result != nil && firstDone == nil { firstDone = Double(i) / 48000 }
        i += n
    }
    let expected = try? Data(contentsOf: URL(fileURLWithPath: env["PAYLOAD"] ?? ""))
    print("result:", td.result == nil ? "incomplete" : (td.result?.data == expected ? "MATCH at \(firstDone!)s" : "decoded (no reference)"))
    exit(0)
}
if env["AUDIO"] != nil {
    let bytes = Int(env["BYTES"] ?? "6000")!
    for snr in (env["SNRS"] ?? "30,20,12").split(separator: ",").map({ Double($0)! }) {
        print("== SNR \(snr) dB, clock 40 ppm, echoes + reverb, \(bytes) bytes")
        for band in AcousticBand.allCases where env["BANDS"] == nil || env["BANDS"]!.contains("\(band.rawValue)") {
            var room = RoomParams(); room.snrDB = snr
            if let ppm = env["PPM"] { room.clockPPM = Double(ppm)! }
            if band != .full { room.highCut = 22_000 }
            for li in 0..<Acoustic.levels.count {
                let lv = Acoustic.levels[li]
                let (ok, sec, fr, q) = acousticSim(band: band, level: li, room: room, bytes: bytes)
                let rate = AcousticFrame.rate(band, li)
                print(String(format: "%@ L%d %dbit p%d | nominal %5.0f B/s  %@  %5.1fs  goodput %5.0f B/s  frames %d ok %3.0f%%",
                             "\(band)".padding(toLength: 10, withPad: " ", startingAt: 0), li, lv.bits, lv.parity, rate, ok ? "✓" : "✗", sec, ok ? Double(bytes) / sec : 0, fr, q * 100))
            }
        }
    }
    exit(0)
}
if env["BIPTEST"] != nil {
    for li in [15, 16, 17, 7] {
        let fit = Ladder.fit(level: li, width: availW, height: availH)!
        let L = FrameLayout.get(level: li, aspect: fit.aspect)
        let enc = TransferEncoder(payload: payload)
        let scr = Channel.screen(layout: L, frame: Renderer.frame(enc, layout: L), cellPx: fit.cellPx, screenW: screenW, screenH: screenH)
        var p = ChannelParams(); p.camW = camW; p.camH = camH
        var cam = Channel.capture(scr, p)
        let fd = FrameDecoder(); fd.bipolar = true
        let (_, a) = cam.withUnsafeBufferPointer { fd.decode(BGRAFrame(base: $0.baseAddress!, width: camW, height: camH, bytesPerRow: camW * 4)) }
        let split = Int(env["SPLIT"] ?? "960")!
        for y in 0..<camH { for x in 0..<split { let o = (y * camW + x) * 4; for c in 0..<3 { cam[o + c] = 255 - cam[o + c] } } }
        let (_, b) = cam.withUnsafeBufferPointer { fd.decode(BGRAFrame(base: $0.baseAddress!, width: camW, height: camH, bytesPerRow: camW * 4)) }
        print("L\(li) normal: found \(a.found) \(a.decoded)/\(a.slots) | half-inverted: found \(b.found) \(b.decoded)/\(b.slots) markers \(b.markersFound)/\(b.markersTotal)")
    }
    exit(0)
}
if env["HIDDEN"] != nil {
    let levels = (env["LEVELS"] ?? "15,16,17,18").split(separator: ",").map { Int($0)! }
    let alphas = (env["ALPHAS"] ?? "0.02,0.03,0.05").split(separator: ",").map { Double($0)! }
    let c = conds[Int(env["COND"] ?? "0")!]
    let dur = Double(env["DUR"] ?? "1.0")!
    print("hidden: cond \(c.name) camera \(camW)x\(camH) window \(Hidden.window) duration \(dur)s")
    for li in levels { for a in alphas {
        let (g, n, fnd, ok) = hiddenSim(level: li, alpha: a, cond: c, duration: dur, seed: UInt64(li * 10))
        let L = Ladder.levels[li]
        print(String(format: "L%2d cols %3d α %.3f | found %2d/%2d  ok/found %5.1f%%  unique goodput %6.2f kB/s", li, L.cols, a, fnd, n, ok * 100, g / 1000))
    } }
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
    if let cf = condFilter, !cf.contains(c.name.trimmingCharacters(in: .whitespaces)) { continue }
    print("== \(c.name)  blur \(c.blur) noise \(c.noise) fill \(c.fill) crosstalk \(c.ct)")
    var bestRate = 0.0, bestLevel = -1
    for li in 0..<Ladder.levels.count {
        if let f = levelFilter, !f.contains(li) { continue }
        guard let fit = Ladder.fit(level: li, width: availW, height: availH) else { continue }
        let L = FrameLayout.get(level: li, aspect: fit.aspect)
        let enc = TransferEncoder(payload: payload)
        let fd = FrameDecoder()
        fd.equalize = env["EQ"] != "0"
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

// MARK: hidden video through the temporal camera model

func hiddenSim(level li: Int, alpha: Double, cond c: Cond, duration: Double, seed: UInt64) -> (goodput: Double, decodes: Int, found: Int, okFrac: Double) {
    guard let fit = Ladder.fit(level: li, width: availW, height: availH) else { return (0, 0, 0, 0) }
    let L = FrameLayout.get(level: li, aspect: fit.aspect)
    let enc = TransferEncoder(payload: payload)
    var patterns: [(RGBAImage, RGBAImage)] = []
    func pattern(_ k: Int) -> (RGBAImage, RGBAImage) {
        while patterns.count <= k {
            let p = Hidden.pattern(layout: L, frame: Renderer.frame(enc, layout: L), cellPx: fit.cellPx)
            patterns.append((p, Hidden.complement(p)))
        }
        return patterns[k]
    }
    var screens: [Int: RGBAImage] = [:]
    func screen(_ f: Int) -> RGBAImage {
        if let s = screens[f] { return s }
        let v = SyntheticVideo.frame(Double(f) / 60, width: screenW, height: screenH)
        let (p, q) = pattern(f / Hidden.window)
        let s = SyntheticVideo.embed(v, pattern: f % 2 == 0 ? p : q, alpha: alpha)
        screens[f] = s
        if let old = screens.keys.min(), screens.count > 12 { screens[old] = nil }
        return s
    }
    let T = 1.0 / 60, readout = 0.012, exposure = 0.004
    var r = SplitMix64Sim(seed)
    var t = T + r.unit() * T
    let demod = HiddenDemodulator()
    let fd = FrameDecoder()
    fd.bipolar = true
    var seen = Set<Int>()
    var i = 0, decodes = 0, found = 0, okSum = 0.0
    while t < duration + T {
        let kmin = max(0, Int(floor((t - T) / T)))
        let kmax = Int(floor((t + readout + exposure) / T)) + 1
        let frames = (kmin...kmax).map { screen($0) }
        var p = ChannelParams()
        p.camW = camW; p.camH = camH
        p.blur = c.blur * Double(camW) / 3840; p.noise = c.noise; p.fill = c.fill; p.crosstalk = c.ct; p.tilt = c.tilt
        p.seed = seed &+ UInt64(i)
        p.geometrySeed = seed
        p.shake = Double(env["SHAKE"] ?? "0.5")!
        p.pixelFill = Double(env["FILL"] ?? "0.7")!
        let H = Double(camH), tt = t
        let cam = Channel.capture(frames: frames, p) { ys, yc in
            let a = tt + Double(yc) / H * readout
            let k = Int(floor((a - ys * T) / T))
            let s = Double(k + 1) * T + ys * T
            return (k - kmin, Float(max(0, min(1, (a + exposure - s) / exposure))))
        }
        // drop captures the way a busy phone does (alwaysDiscardsLateVideoFrames)
        let dropP = Double(env["DROP"] ?? "0")!
        if r.unit() >= dropP {
            cam.withUnsafeBufferPointer { demod.push(BGRAFrame(base: $0.baseAddress!, width: camW, height: camH, bytesPerRow: camW * 4), time: tt) }
        }
        if i % 4 == 0, let img = demod.render() {
            let (pk, st) = img.withFrame { fd.decode($0) }
            decodes += 1
            if st.found { found += 1; okSum += Double(st.decoded) / Double(max(1, st.slots)) }
            for q in pk where q.type == .data { seen.insert(q.block << 16 | q.id) }
            if env["DUMP"] != nil && decodes == 3 { img.withFrame { f in writePNG(f, env["DUMP"]!) } }
        }
        i += 1
        t += T
    }
    return (Double(seen.count) * Double(Wire.symbolSize) / duration, decodes, found, found > 0 ? okSum / Double(found) : 0)
}

func writePNG(_ f: BGRAFrame, _ path: String) {
    let data = Data(bytes: f.base, count: f.height * f.bytesPerRow) as CFData
    let cg = CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.bytesPerRow,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                     provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, cg, nil)
    CGImageDestinationFinalize(dst)
}


// MARK: acoustic modem through a simulated room

func acousticSim(band: AcousticBand, level: Int, room: RoomParams, bytes: Int) -> (ok: Bool, seconds: Double, frames: Int, decodedFrac: Double) {
    var rng = SplitMix64Sim(9)
    let data = Data((0..<bytes).map { _ in UInt8(truncatingIfNeeded: Int(rng.unit() * 256)) })
    let enc = TransferEncoder(payload: Payload(kind: .file, name: "a.bin", data: data))
    let tx = AcousticTransmitter(encoder: enc, band: band, level: level)
    let rx = AcousticReceiver()
    let td = TransferDecoder()
    var samples = [Float](repeating: 0, count: 3_000)   // leading silence
    var total = 0, frames = 0, decoded = 0, slots = 0
    var r = room
    while td.result == nil && frames < 400 {
        samples += tx.nextFrame()
        r.seed = room.seed &+ UInt64(frames)
        let heard = Room.apply(samples, r)
        total += samples.count
        samples.removeAll()
        heard.withUnsafeBufferPointer { b in
            var i = 0
            while i < b.count {
                let n = min(1024, b.count - i)
                for q in rx.process(UnsafeBufferPointer(rebasing: b[i..<(i + n)])) { td.ingest(q) }
                i += n
            }
        }
        frames += 1
        decoded += rx.stats.decoded; slots += rx.stats.slots
    }
    return (td.result?.data == data, Double(total) / Acoustic.sampleRate, frames, slots > 0 ? Double(decoded) / Double(slots) : 0)
}

func writeWAV(_ x: [Float], _ path: String) {
    var d = Data()
    func u32(_ v: UInt32) { var v = v.littleEndian; d.append(Data(bytes: &v, count: 4)) }
    func u16(_ v: UInt16) { var v = v.littleEndian; d.append(Data(bytes: &v, count: 2)) }
    d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + x.count * 2)); d.append("WAVEfmt ".data(using: .ascii)!)
    u32(16); u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16)
    d.append("data".data(using: .ascii)!); u32(UInt32(x.count * 2))
    for v in x { u16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32767))) }
    try! d.write(to: URL(fileURLWithPath: path))
}

func readWAV(_ path: String) -> [Float] {
    let d = try! Data(contentsOf: URL(fileURLWithPath: path))
    // find "data" chunk; expects 16-bit mono 48 kHz
    var i = 12
    while i + 8 <= d.count {
        let id = String(data: d[i..<(i + 4)], encoding: .ascii)
        let size = Int(d[i + 4]) | Int(d[i + 5]) << 8 | Int(d[i + 6]) << 16 | Int(d[i + 7]) << 24
        if id == "data" {
            let start = i + 8, n = min(size, d.count - start) / 2
            return (0..<n).map { k in Float(Int16(bitPattern: UInt16(d[start + 2 * k]) | UInt16(d[start + 2 * k + 1]) << 8)) / 32768 }
        }
        i += 8 + size
    }
    return []
}
