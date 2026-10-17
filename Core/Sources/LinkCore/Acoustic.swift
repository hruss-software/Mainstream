import Foundation
import Accelerate

// Acoustic modem: differential OFDM over speaker → microphone.
// 48 kHz, 1024-point symbols with a 256-sample cyclic prefix and 32-sample windowed overlap
// (no clicks, which matters in the near-ultrasonic band). Each frame:
//   chirp preamble · gap · reference symbol · header symbol · D data symbols · tail silence
// Data rides as phase differences between consecutive symbols on each carrier
// (DBPSK / DQPSK / D8PSK, Gray coded), so no channel estimate is needed. Codeword bits are
// spread over all carriers and symbols by a fixed permutation, and the same packets,
// Reed–Solomon (with erasures) and fountain code as the visual link carry the payload.

public enum AcousticBand: Int, CaseIterable, Sendable {
    case audible = 0, full = 1, ultrasonic = 2

    public var range: (lo: Double, hi: Double) {
        switch self {
        case .audible: return (500, 15_000)
        case .full: return (200, 20_500)
        case .ultrasonic: return (17_500, 21_500)
        }
    }

    var carriers: Range<Int> {
        let r = range
        return Int((r.lo / Acoustic.binHz).rounded(.up))..<(Int((r.hi / Acoustic.binHz).rounded(.down)) + 1)
    }
}

public struct AcousticLevel: Sendable {
    public let bits: Int
    public let parity: Int
}

public enum Acoustic {
    public static let sampleRate = 48_000.0
    static let N = 1024
    static let CP = 256
    static let taper = 32
    static let backoff = 64
    static let chirpLength = 4096
    static let gap = 512
    static let tail = 2048
    static var binHz: Double { sampleRate / Double(N) }
    static var symbolLength: Int { N + CP }

    public static let levels: [AcousticLevel] = [
        AcousticLevel(bits: 1, parity: 48),
        AcousticLevel(bits: 2, parity: 48),
        AcousticLevel(bits: 2, parity: 32),
        AcousticLevel(bits: 3, parity: 48),
        AcousticLevel(bits: 3, parity: 32),
    ]
    public static let defaultLevel = 2

    static func chirp(_ band: AcousticBand) -> [Float] {
        let (lo, hi) = band.range
        let L = chirpLength
        var c = [Float](repeating: 0, count: L)
        let T = Double(L) / sampleRate
        let k = (hi - lo) / T
        for i in 0..<L {
            let t = Double(i) / sampleRate
            let ph = 2 * Double.pi * (lo * t + 0.5 * k * t * t)
            // Tukey window (10 % tapers)
            let u = Double(i) / Double(L - 1)
            let w = u < 0.1 ? 0.5 - 0.5 * cos(.pi * u / 0.1) : (u > 0.9 ? 0.5 - 0.5 * cos(.pi * (1 - u) / 0.1) : 1)
            c[i] = Float(sin(ph) * w)
        }
        return c
    }

    static func referencePhases(_ band: AcousticBand) -> [Int] {
        var r = SplitMix64(0xA11CE ^ UInt64(band.rawValue))
        return band.carriers.map { _ in Int(r.next() & 3) }   // QPSK phases (×π/2)
    }

    static func header(level: Int, band: AcousticBand) -> [Bool] {
        let byte = UInt8(level << 5 | band.rawValue << 3)
        let crc = UInt8(truncatingIfNeeded: CRC16.compute([byte, 0xA5]))
        let v = UInt16(byte) << 8 | UInt16(crc)
        return (0..<16).map { (v >> UInt16(15 - $0)) & 1 == 1 }
    }

    static func parseHeader(_ bits: [Bool], band: AcousticBand) -> Int? {
        var v: UInt16 = 0
        for b in bits { v = v << 1 | (b ? 1 : 0) }
        let byte = UInt8(v >> 8), crc = UInt8(v & 0xff)
        guard UInt8(truncatingIfNeeded: CRC16.compute([byte, 0xA5])) == crc else { return nil }
        guard Int((byte >> 3) & 3) == band.rawValue else { return nil }
        let level = Int(byte >> 5)
        return level < levels.count ? level : nil
    }
}

/// Per (band, level) frame geometry.
public final class AcousticFrame {
    let band: AcousticBand
    let level: AcousticLevel
    let K: Int
    let n: Int
    let slots: Int
    let symbols: Int
    let perm: [Int32]           // codeword bit → frame bit position
    let scramble: [UInt8]
    let rs: ReedSolomon

    private static var cache: [Int: AcousticFrame] = [:]
    private static let lock = NSLock()

    static func get(_ band: AcousticBand, _ li: Int) -> AcousticFrame {
        lock.lock(); defer { lock.unlock() }
        let key = band.rawValue * 16 + li
        if let f = cache[key] { return f }
        let f = AcousticFrame(band, li)
        cache[key] = f
        return f
    }

    private init(_ band: AcousticBand, _ li: Int) {
        self.band = band
        level = Acoustic.levels[li]
        K = band.carriers.count
        n = Wire.messageSize + level.parity
        let b = level.bits
        slots = max(2, (32 * K * b) / (8 * n))
        // each codeword byte sits on one carrier (8 consecutive bits of that carrier's stream),
        // so a weak carrier corrupts whole bytes the erasure decoder can drop
        let bytesPerCarrier = (slots * n + K - 1) / K
        symbols = (bytesPerCarrier * 8 + b - 1) / b
        var places = [(Int, Int)]()
        for j in 0..<K { for u in 0..<bytesPerCarrier { places.append((j, u)) } }
        var r = SplitMix64(0xB17 ^ UInt64(band.rawValue * 16 + li))
        for i in stride(from: places.count - 1, to: 0, by: -1) {
            let j = Int(r.next() % UInt64(i + 1))
            places.swapAt(i, j)
        }
        var p = [Int32](repeating: 0, count: slots * n * 8)
        for c in 0..<(slots * n) {
            let (j, u) = places[c]
            for q in 0..<8 {
                let t = 8 * u + q
                p[c * 8 + q] = Int32(((t / b) * K + j) * b + t % b)
            }
        }
        perm = p
        var sc = [UInt8](repeating: 0, count: slots * n)
        for i in 0..<sc.count { sc[i] = UInt8(truncatingIfNeeded: r.next()) }
        scramble = sc
        rs = ReedSolomon(parity: level.parity)
    }

    var sampleCount: Int {
        Acoustic.chirpLength + Acoustic.gap + (symbols + 2) * Acoustic.symbolLength + Acoustic.taper + Acoustic.tail
    }

    public static func rate(_ b: AcousticBand, _ l: Int) -> Double { get(b, l).payloadRate }

    var payloadRate: Double {
        Double(slots - 1) * Double(Wire.symbolSize) * Acoustic.sampleRate / Double(sampleCount)
    }
}

final class FFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init(_ n: Int) {
        self.n = n
        log2n = vDSP_Length(log2(Double(n)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func transform(_ re: inout [Float], _ im: inout [Float], inverse: Bool) {
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var s = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &s, 1, log2n, FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward))
            }
        }
    }
}

// MARK: - transmitter

public final class AcousticTransmitter {
    public let band: AcousticBand
    public let levelIndex: Int
    let encoder: TransferEncoder
    private let fft = FFT(Acoustic.N)

    public init(encoder: TransferEncoder, band: AcousticBand, level: Int) {
        self.encoder = encoder
        self.band = band
        self.levelIndex = level
    }

    public var payloadRate: Double { AcousticFrame.get(band, levelIndex).payloadRate }

    /// Next frame of mono samples at 48 kHz in [-1, 1].
    public func nextFrame() -> [Float] {
        let F = AcousticFrame.get(band, levelIndex)
        let b = F.level.bits, M = 1 << b
        let K = F.K
        let n = F.n
        // codewords → frame bits
        var msgs = [UInt8](repeating: 0, count: F.slots * Wire.messageSize)
        msgs.withUnsafeMutableBufferPointer { encoder.nextMessages(slots: F.slots, into: $0.baseAddress!) }
        var bits = [UInt8](repeating: 0, count: F.symbols * K * b)
        var r = SplitMix64(UInt64(encoder.session) ^ 0x51CE)
        for i in 0..<bits.count { bits[i] = UInt8(r.next() & 1) }
        var cw = [UInt8](repeating: 0, count: n)
        for s in 0..<F.slots {
            msgs.withUnsafeBufferPointer { m in
                cw.withUnsafeMutableBufferPointer { c in
                    c.baseAddress!.update(from: m.baseAddress! + s * Wire.messageSize, count: Wire.messageSize)
                    F.rs.encode(UnsafePointer(c.baseAddress!), count: Wire.messageSize, parityOut: c.baseAddress! + Wire.messageSize)
                }
            }
            for i in 0..<n {
                let byte = cw[i] ^ F.scramble[s * n + i]
                for j in 0..<8 {
                    bits[Int(F.perm[(s * n + i) * 8 + j])] = (byte >> UInt8(7 - j)) & 1
                }
            }
        }
        // symbols
        var out = [Float](repeating: 0, count: F.sampleCount)
        let chirp = Acoustic.chirp(band)
        for i in 0..<chirp.count { out[i] = chirp[i] * 0.5 }
        var pos = Acoustic.chirpLength + Acoustic.gap
        var phase = Acoustic.referencePhases(band).map { $0 * (M >= 4 ? M / 4 : 1) }   // in units of 2π/M (or π for M=2)
        let unit: Double
        if M == 2 {
            // BPSK reference uses QPSK phases mod 2 in π units
            phase = Acoustic.referencePhases(band).map { $0 & 1 }
            unit = Double.pi
        } else {
            unit = 2 * Double.pi / Double(M)
        }
        let carriers = Array(band.carriers)
        func emit(_ ph: [Int]) {
            var re = [Float](repeating: 0, count: Acoustic.N), im = re
            for (j, k) in carriers.enumerated() {
                let a = Double(ph[j]) * unit
                re[k] = Float(cos(a)); im[k] = Float(sin(a))
                re[Acoustic.N - k] = Float(cos(a)); im[Acoustic.N - k] = -Float(sin(a))
            }
            fft.transform(&re, &im, inverse: true)
            // RMS normalise to ~0.22, windowed overlap-add
            var e: Float = 0
            for v in re { e += v * v }
            let g = 0.22 / max(1e-9, sqrt(e / Float(Acoustic.N)))
            let T = Acoustic.taper, CP = Acoustic.CP, Nn = Acoustic.N
            for i in 0..<(CP + Nn + T) {
                let src = (i - CP + Nn) % Nn
                var w: Float = 1
                if i < T { w = 0.5 - 0.5 * cos(Float.pi * Float(i) / Float(T)) }
                if i >= CP + Nn { w = 0.5 + 0.5 * cos(Float.pi * Float(i - CP - Nn) / Float(T)) }
                out[pos + i] += re[src] * g * w
            }
            pos += CP + Nn
        }
        emit(phase)
        // header: DBPSK on every carrier relative to the reference, repeated bit pattern
        let hdr = Acoustic.header(level: levelIndex, band: band)
        let half = M == 2 ? 1 : M / 2
        phase = phase.enumerated().map { (j, p) in (p + (hdr[j % 16] ? half : 0)) % M }
        emit(phase)
        for s in 0..<F.symbols {
            for j in 0..<K {
                var v = 0
                for q in 0..<b { v = v << 1 | Int(bits[(s * K + j) * b + q]) }
                phase[j] = (phase[j] + inverseGray(v)) % M
            }
            emit(phase)
        }
        for i in 0..<out.count { out[i] = max(-0.98, min(0.98, out[i])) }
        return out
    }
}

@inline(__always) func inverseGray(_ g: Int) -> Int {
    var v = g, s = g >> 1
    while s != 0 { v ^= s; s >>= 1 }
    return v
}

// MARK: - receiver

public struct AcousticStats: Sendable {
    public var band: AcousticBand? = nil
    public var level: Int? = nil
    public var frames = 0
    public var slots = 0
    public var decoded = 0
    public var corrections = 0
    public var parity = 0
    public var lastPeak: Float = 0
}

public final class AcousticReceiver {
    public var bands: [AcousticBand] = AcousticBand.allCases
    public var threshold: Float = 0.22
    public private(set) var stats = AcousticStats()
    private var buf: [Float] = []
    private var base = 0                 // absolute index of buf[0]
    private var searchPos = 0
    private var pending: (band: AcousticBand, start: Int)? = nil
    private let fft = FFT(Acoustic.N)
    private let corrFFT = FFT(8192)
    private var chirpSpec: [AcousticBand: ([Float], [Float], Float)] = [:]

    public init() {
        for b in AcousticBand.allCases {
            let c = Acoustic.chirp(b)
            var re = [Float](repeating: 0, count: 8192), im = re
            for i in 0..<c.count { re[i] = c[i] }
            corrFFT.transform(&re, &im, inverse: false)
            chirpSpec[b] = (re, im, sqrt(c.reduce(0) { $0 + $1 * $1 }))
        }
    }

    /// Feeds mono 48 kHz samples; returns any packets completed.
    public func process(_ samples: UnsafeBufferPointer<Float>) -> [Packet] {
        buf.append(contentsOf: samples)
        var out: [Packet] = []
        while true {
            if let p = pending {
                // need header first
                let hdrEnd = p.start + 2 * Acoustic.symbolLength + Acoustic.taper
                if base + buf.count < hdrEnd { break }
                guard let li = readHeader(p.band, p.start) else {
                    pending = nil
                    continue
                }
                let F = AcousticFrame.get(p.band, li)
                let end = p.start + (F.symbols + 2) * Acoustic.symbolLength + Acoustic.taper
                if base + buf.count < end { break }
                out += demodulate(F, li, p.start)
                searchPos = end
                pending = nil
                continue
            }
            // search a hop of 4096 lags
            let hop = 4096
            if base + buf.count < searchPos + hop + Acoustic.chirpLength { break }
            if let (band, lag, peak) = search(at: searchPos, hop: hop) {
                // refine around the hop-local maximum (the true peak may sit just past the hop)
                if base + buf.count < lag + 256 + Acoustic.chirpLength { break }
                let p = refine(band, lag)
                stats.lastPeak = peak
                pending = (band, p + Acoustic.chirpLength + Acoustic.gap)
                searchPos = p + Acoustic.chirpLength
            } else {
                searchPos += hop
            }
        }
        // trim
        let keepFrom = min(searchPos, pending?.start ?? searchPos) - 4 * Acoustic.chirpLength
        if keepFrom - base > 48_000 {
            let drop = keepFrom - base
            buf.removeFirst(drop)
            base += drop
        }
        return out
    }

    private func search(at pos: Int, hop: Int) -> (AcousticBand, Int, Float)? {
        let off = pos - base
        var re = [Float](repeating: 0, count: 8192), im = re
        for i in 0..<min(8192, buf.count - off) { re[i] = buf[off + i] }
        // running energy for normalisation
        var cum = [Float](repeating: 0, count: 8193)
        for i in 0..<8192 { cum[i + 1] = cum[i] + re[i] * re[i] }
        corrFFT.transform(&re, &im, inverse: false)
        var best: (AcousticBand, Int, Float)? = nil
        for band in bands {
            guard let (cr, ci, cn) = chirpSpec[band] else { continue }
            var pr = [Float](repeating: 0, count: 8192), pi = pr
            for i in 0..<8192 {
                // X · conj(C)
                pr[i] = re[i] * cr[i] + im[i] * ci[i]
                pi[i] = im[i] * cr[i] - re[i] * ci[i]
            }
            corrFFT.transform(&pr, &pi, inverse: true)
            for l in 0..<hop {
                let e = cum[l + Acoustic.chirpLength] - cum[l]
                if e <= 1e-9 { continue }
                let v = pr[l] / 8192 / (cn * sqrt(e))
                if v > threshold && v > (best?.2 ?? 0) { best = (band, pos + l, v) }
            }
        }
        return best
    }

    private func refine(_ band: AcousticBand, _ lag: Int) -> Int {
        let c = Acoustic.chirp(band)
        var best = lag, bv = -Float.greatestFiniteMagnitude
        for l in max(base, lag - 128)...(lag + 128) {
            let off = l - base
            var acc: Float = 0, e: Float = 0
            for j in 0..<c.count { let v = buf[off + j]; acc += v * c[j]; e += v * v }
            let nv = acc / sqrt(max(e, 1e-9))
            if nv > bv { bv = nv; best = l }
        }
        return best
    }

    private func spectrum(at absStart: Int) -> ([Float], [Float]) {
        let off = absStart - base + Acoustic.CP - Acoustic.backoff
        var re = [Float](repeating: 0, count: Acoustic.N), im = re
        for i in 0..<Acoustic.N where off + i >= 0 && off + i < buf.count { re[i] = buf[off + i] }
        fft.transform(&re, &im, inverse: false)
        return (re, im)
    }

    private func readHeader(_ band: AcousticBand, _ start: Int) -> Int? {
        let carriers = Array(band.carriers)
        let (r0, i0) = spectrum(at: start)
        let (r1, i1) = spectrum(at: start + Acoustic.symbolLength)
        var soft = [Float](repeating: 0, count: 16)
        for (j, k) in carriers.enumerated() {
            // Re(Z1·conj(Z0)) < 0 means a π flip
            let d = r1[k] * r0[k] + i1[k] * i0[k]
            let mag = sqrt((r1[k] * r1[k] + i1[k] * i1[k]) * (r0[k] * r0[k] + i0[k] * i0[k])) + 1e-9
            soft[j % 16] += d / mag
        }
        return Acoustic.parseHeader(soft.map { $0 < 0 }, band: band)
    }

    private func demodulate(_ F: AcousticFrame, _ li: Int, _ start: Int) -> [Packet] {
        stats.frames += 1
        stats.band = F.band
        stats.level = li
        stats.slots = F.slots
        stats.parity = F.level.parity
        let b = F.level.bits, M = 1 << b
        let K = F.K
        let carriers = Array(F.band.carriers)
        let unit = M == 2 ? Float.pi : 2 * Float.pi / Float(M)
        var bits = [UInt8](repeating: 0, count: F.symbols * K * b)
        var rel = [Float](repeating: 0, count: F.symbols * K * b)
        var prev = spectrum(at: start + Acoustic.symbolLength)   // header symbol
        let kc = Float(K - 1) / 2
        for s in 0..<F.symbols {
            let cur = spectrum(at: start + (s + 2) * Acoustic.symbolLength)
            var th = [Float](repeating: 0, count: K), amp = th
            for (j, k) in carriers.enumerated() {
                let dr = cur.0[k] * prev.0[k] + cur.1[k] * prev.1[k]
                let di = cur.1[k] * prev.0[k] - cur.0[k] * prev.1[k]
                th[j] = atan2(di, dr)
                amp[j] = sqrt(dr * dr + di * di)
            }
            // decision-directed removal of common phase + linear slope (clock offset, Doppler)
            var idx = [Int](repeating: 0, count: K), err = th
            for _ in 0..<3 {
                var sw: Float = 0, se: Float = 0, sk: Float = 0, skk: Float = 0, ske: Float = 0
                for j in 0..<K {
                    let q = Int((th[j] / unit).rounded())
                    idx[j] = ((q % M) + M) % M
                    var e = th[j] - Float(q) * unit
                    if e > Float.pi { e -= 2 * Float.pi } else if e < -Float.pi { e += 2 * Float.pi }
                    err[j] = e
                    let w = amp[j], x = Float(j) - kc
                    sw += w; se += w * e; sk += w * x; skk += w * x * x; ske += w * x * e
                }
                if sw <= 0 { break }
                let a = se / sw
                let c = skk > 0 ? (ske - sk * a) / skk : 0
                if abs(a) < 1e-4 && abs(c) < 1e-6 { break }
                for j in 0..<K { th[j] -= a + c * (Float(j) - kc) }
            }
            var sorted = amp.sorted()
            let med = max(1e-9, sorted[K / 2])
            sorted.removeAll()
            for j in 0..<K {
                let v = idx[j] ^ (idx[j] >> 1)
                let margin = max(0, 1 - abs(err[j]) / (unit / 2))
                let r = margin * min(1, amp[j] / med)
                for q in 0..<b {
                    let p = (s * K + j) * b + q
                    bits[p] = UInt8((v >> (b - 1 - q)) & 1)
                    rel[p] = r
                }
            }
            prev = cur
        }
        // codewords
        var packets: [Packet] = []
        let n = F.n
        var corrections = 0
        for slot in 0..<F.slots {
            var cw = [UInt8](repeating: 0, count: n)
            var crel = [Float](repeating: 0, count: n)
            for i in 0..<n {
                var byte: UInt8 = 0
                var mr: Float = 1e9
                for j in 0..<8 {
                    let p = Int(F.perm[(slot * n + i) * 8 + j])
                    byte = byte << 1 | bits[p]
                    mr = min(mr, rel[p])
                }
                cw[i] = byte ^ F.scramble[slot * n + i]
                crel[i] = mr
            }
            if let (p, c) = decodeCodeword(cw, crel, F) { packets.append(p); corrections += c }
        }
        stats.decoded = packets.count
        stats.corrections = corrections
        return packets
    }

    private func decodeCodeword(_ cw0: [UInt8], _ rel: [Float], _ F: AcousticFrame) -> (Packet, Int)? {
        var cw = cw0
        if let c = F.rs.decode(&cw), let p = cw.withUnsafeBufferPointer({ parseMessage($0.baseAddress!) }) { return (p, c) }
        let order = (0..<F.n).sorted { rel[$0] < rel[$1] }
        let t2 = F.level.parity
        for f in [t2 / 2, (t2 * 3) / 4, t2 - 2] {
            cw = cw0
            if let c = F.rs.decode(&cw, erasures: Array(order.prefix(f))),
               let p = cw.withUnsafeBufferPointer({ parseMessage($0.baseAddress!) }) { return (p, c) }
        }
        return nil
    }
}

// MARK: - simulated room

public struct RoomParams {
    public var snrDB = 25.0
    public var clockPPM = 40.0
    public var echoes: [(delay: Int, gain: Float)] = [(37, 0.35), (151, 0.2), (410, 0.12)]
    public var reverb: Float = 0.05      // diffuse tail level
    public var lowCut = 250.0            // speaker high-pass
    public var highCut = 16_000.0        // speaker/mic roll-off
    public var seed: UInt64 = 1
    public init() {}
}

public enum Room {
    public static func apply(_ x: [Float], _ p: RoomParams) -> [Float] {
        var r = SplitMix64(p.seed)
        func gauss() -> Float {
            let u1 = max(1e-12, Double(r.next() >> 11) / Double(1 << 53)), u2 = Double(r.next() >> 11) / Double(1 << 53)
            return Float(sqrt(-2 * log(u1)) * cos(2 * .pi * u2))
        }
        // resample (clock offset)
        let ratio = 1 + p.clockPPM * 1e-6
        let n = Int(Double(x.count) / ratio)
        var y = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) * ratio
            let a = Int(t), f = Float(t - Double(a))
            y[i] = a + 1 < x.count ? x[a] * (1 - f) + x[a + 1] * f : 0
        }
        // first-order high-pass and two-pole low-pass
        let fs = Acoustic.sampleRate
        let ah = Float(1 / (1 + 2 * .pi * p.lowCut / fs))
        var prevX: Float = 0, prevY: Float = 0
        for i in 0..<n { let v = ah * (prevY + y[i] - prevX); prevX = y[i]; prevY = v; y[i] = v }
        let al = Float(1 - exp(-2 * .pi * p.highCut / fs))
        for _ in 0..<2 { var s: Float = 0; for i in 0..<n { s += al * (y[i] - s); y[i] = s } }
        // multipath + diffuse reverb
        var z = y
        for (d, g) in p.echoes { for i in d..<n { z[i] += g * y[i - d] } }
        if p.reverb > 0 {
            var taps: [(Int, Float)] = []
            for _ in 0..<60 {
                let d = 500 + Int(r.next() % 4000)
                taps.append((d, p.reverb * exp(-Float(d) / 1500) * gauss()))
            }
            for (d, g) in taps { for i in d..<n { z[i] += g * y[i - d] } }
        }
        // noise
        var e: Float = 0
        for v in z { e += v * v }
        let sigma = sqrt(e / Float(max(1, n)) / Float(pow(10, p.snrDB / 10)))
        for i in 0..<n { z[i] += sigma * gauss() }
        return z
    }
}
