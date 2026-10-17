import Foundation
import Accelerate

// Acoustic modem: coded OFDM over speaker → microphone.
// 48 kHz, 2048-point symbols with a 1024-sample (21 ms) cyclic prefix that outlasts room
// echoes. Each frame (about four seconds of data, so sync overhead stays small):
//   chirp preamble · gap · reference symbol · header symbol · data symbols · short tail
// Every 8th carrier is a known pilot used to track clock offset and drift. Data carriers carry
// BPSK or QPSK. Reed–Solomon packets are concatenated, protected by a rate-1/2 or 3/4
// convolutional code, spread over all carriers and symbols by an interleaver, and decoded with
// soft-decision Viterbi where each carrier's bits are weighted by how noisy it was.

public enum AcousticBand: Int, CaseIterable, Sendable {
    case audible = 0, full = 1, ultrasonic = 2

    public var range: (lo: Double, hi: Double) {
        switch self {
        case .audible: return (500, 15_000)
        case .full: return (200, 20_500)
        case .ultrasonic: return (17_500, 21_500)
        }
    }

    public var carriers: Range<Int> {
        let r = range
        return Int((r.lo / Acoustic.binHz).rounded(.up))..<(Int((r.hi / Acoustic.binHz).rounded(.down)) + 1)
    }
}

public struct AcousticLevel: Sendable {
    public let bits: Int          // per carrier: 1 = BPSK, 2 = QPSK, 4 = 16-QAM, 6 = 64-QAM
    public let code: CodeRate
    public let parity: Int        // Reed–Solomon parity bytes per packet
}

/// Square, Gray-mapped constellations with unit average energy. BPSK uses the real axis only;
/// the others put half the bits on each axis, so every axis is an independent Gray-coded PAM.
public struct Constellation: Sendable {
    public let bits: Int
    let axisBits: Int
    let m: Int                    // levels per axis
    let amp: [Float]              // amplitude of position t (ascending)
    let label: [Int]              // Gray label of position t
    let half: Float               // half the distance between neighbouring levels

    public init(bits: Int) {
        self.bits = bits
        axisBits = bits == 1 ? 1 : bits / 2
        let m = 1 << axisBits
        self.m = m
        let scale: Float = bits == 1 ? 1 : sqrt(2 * Float(m * m - 1) / 3)
        amp = (0..<m).map { Float(2 * $0 - (m - 1)) / scale }
        label = (0..<m).map { let t = m - 1 - $0; return t ^ (t >> 1) }   // bit 0 on the positive side, as BPSK/QPSK always were
        half = 1 / scale
    }

    /// Point for a symbol label (I bits high, Q bits low).
    public func point(_ idx: Int) -> (Float, Float) {
        if bits == 1 { return (amp[label.firstIndex(of: idx)!], 0) }
        let mask = m - 1
        return (amp[label.firstIndex(of: idx >> axisBits)!], amp[label.firstIndex(of: idx & mask)!])
    }

    func point(bits b: UnsafePointer<UInt8>) -> (Float, Float) {
        var idx = 0
        for q in 0..<bits { idx = idx << 1 | Int(b[q]) }
        return point(idx)
    }

    private func slice(_ v: Float) -> Int { max(0, min(m - 1, Int(((v / half + Float(m - 1)) / 2).rounded()))) }

    /// Nearest point: its label, and the larger per-axis error in units of half the level spacing.
    func decide(_ yr: Float, _ yi: Float) -> (idx: Int, err: Float) {
        let ti = slice(yr)
        if bits == 1 { return (label[ti], abs(yr - amp[ti]) / half) }
        let tq = slice(yi)
        return (label[ti] << axisBits | label[tq], max(abs(yr - amp[ti]), abs(yi - amp[tq])) / half)
    }

    /// Max-log LLRs (positive = 0) for complex noise variance `n2`, written to out[0..<bits].
    public func llr(_ yr: Float, _ yi: Float, _ n2: Float, into out: UnsafeMutablePointer<Float>) {
        func axis(_ v: Float, _ o: UnsafeMutablePointer<Float>) {
            for q in 0..<axisBits {
                let bit = axisBits - 1 - q
                var d0 = Float.greatestFiniteMagnitude, d1 = d0
                for t in 0..<m {
                    let d = (v - amp[t]) * (v - amp[t])
                    if (label[t] >> bit) & 1 == 0 { d0 = min(d0, d) } else { d1 = min(d1, d) }
                }
                o[q] = (d1 - d0) / n2
            }
        }
        axis(yr, out)
        if bits > 1 { axis(yi, out + axisBits) }
    }
}

public enum Acoustic {
    public static let sampleRate = 48_000.0
    /// FFT length and cyclic prefix (samples). The prefix must outlast the room's strong echoes.
    public static var N = 2048
    public static var CP = 1024
    /// Diagnostic timing shift applied after sync (samples).
    public static var timingShift = 0
    static let taper = 32
    /// Every 8th carrier is a known pilot, so each symbol's phase rotation (clock offset,
    /// Doppler) is measured directly instead of from the receiver's own decisions.
    static let pilotSpacing = 8
    public static var usePilotRotation = true   // diagnostics
    public static var debugPilots = false
    /// Diagnostics: receives each frame's pilot phases (symbol × pilot), pilot weights and bins.
    /// Symbols either side averaged for the pilot channel and for decision refinement.
    public static var pilotWindow = 8
    public static var decisionWindow = 8
    public static var pilotDump: (([[Float]], [Float], [Int]) -> Void)? = nil

    static func pilotPhase(_ symbol: Int, _ i: Int) -> Float {
        var r = SplitMix64(UInt64(symbol) &* 0x9E37 ^ UInt64(i) &* 0x85EB)
        return Float(r.next() & 3) * .pi / 2
    }
    static var backoff: Int { CP / 8 }
    static let chirpLength = 4096
    public static var gap = 2048   // lets the chirp's room echo die before the reference
    static let tail = 512
    public static var frameSeconds = 4.0
    static var binHz: Double { sampleRate / Double(N) }
    static var symbolLength: Int { N + CP }

    // Ordered by speed. Tuned on a real speaker → microphone path: soft-decision convolutional
    // coding is what makes QPSK usable on phone speakers.
    public static let levels: [AcousticLevel] = [
        AcousticLevel(bits: 1, code: .half, parity: 32),
        AcousticLevel(bits: 2, code: .half, parity: 32),
        AcousticLevel(bits: 2, code: .threeQuarters, parity: 32),
        AcousticLevel(bits: 4, code: .half, parity: 32),
        AcousticLevel(bits: 4, code: .threeQuarters, parity: 32),
        AcousticLevel(bits: 6, code: .threeQuarters, parity: 32),
    ]
    public static let defaultLevel = 2
    /// Estimated capacity (bits per data carrier, see `AcousticStats.capacity`) each level needs
    /// to decode reliably, calibrated in the room simulator.
    public static let capacityNeeded: [Double] = [1.8, 2.3, 3.2, 3.5, 4.6, 6.1]

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
    let K: Int                  // data carriers
    let bins: [Int]             // all carriers (FFT bins)
    let pilotPos: [Int]         // indices into `bins` carrying known pilots
    let dataPos: [Int]          // indices into `bins` carrying data
    let n: Int
    let slots: Int
    let symbols: Int
    let coded: Int              // coded bits per frame
    let perm: [Int32]           // coded bit → frame bit position
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
        bins = Array(band.carriers)
        pilotPos = bins.indices.filter { $0 % Acoustic.pilotSpacing == 0 }
        dataPos = bins.indices.filter { $0 % Acoustic.pilotSpacing != 0 }
        K = dataPos.count
        n = Wire.messageSize + level.parity
        let b = level.bits
        // about four seconds of data per frame, so the chirp/reference overhead stays small
        let targetSymbols = Int(Acoustic.frameSeconds * Acoustic.sampleRate) / Acoustic.symbolLength
        let capacity = Double(targetSymbols * K * b) * level.code.ratio
        slots = max(2, Int(capacity) / (8 * n))
        coded = level.code.codedLength(slots * n * 8)
        symbols = (coded + K * b - 1) / (K * b)
        // interleave coded bits over every carrier and symbol
        var r = SplitMix64(0xB17 ^ UInt64(band.rawValue * 16 + li))
        var p = (0..<(symbols * K * b)).map { Int32($0) }
        for i in stride(from: p.count - 1, to: 0, by: -1) {
            let j = Int(r.next() % UInt64(i + 1))
            p.swapAt(i, j)
        }
        perm = Array(p.prefix(coded))
        var sc = [UInt8](repeating: 0, count: slots * n)
        for i in 0..<sc.count { sc[i] = UInt8(truncatingIfNeeded: r.next()) }
        scramble = sc
        rs = ReedSolomon(parity: level.parity)
    }

    var sampleCount: Int {
        Acoustic.chirpLength + Acoustic.gap + (symbols + 2) * Acoustic.symbolLength + Acoustic.taper + Acoustic.tail
    }

    public static func rate(_ b: AcousticBand, _ l: Int) -> Double { get(b, l).payloadRate }
    public static func sampleCountFor(_ b: AcousticBand, _ l: Int) -> Int { get(b, l).sampleCount }
    public static func chirpTemplate(_ b: AcousticBand) -> [Float] { Acoustic.chirp(b) }

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
        let b = F.level.bits
        let K = F.K
        let n = F.n
        // codewords → information bits → convolutional code → interleaved frame bits
        var msgs = [UInt8](repeating: 0, count: F.slots * Wire.messageSize)
        msgs.withUnsafeMutableBufferPointer { encoder.nextMessages(slots: F.slots, into: $0.baseAddress!) }
        var info = [UInt8]()
        info.reserveCapacity(F.slots * n * 8)
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
                for j in 0..<8 { info.append((byte >> UInt8(7 - j)) & 1) }
            }
        }
        let codedBits = Convolutional.encode(info, rate: F.level.code)
        var bits = [UInt8](repeating: 0, count: F.symbols * K * b)
        var r = SplitMix64(UInt64(encoder.session) ^ 0x51CE)
        for i in 0..<bits.count { bits[i] = UInt8(r.next() & 1) }
        for (c, v) in codedBits.enumerated() { bits[Int(F.perm[c])] = v }
        // symbols
        var out = [Float](repeating: 0, count: F.sampleCount)
        let chirp = Acoustic.chirp(band)
        for i in 0..<chirp.count { out[i] = chirp[i] * 0.5 }
        var pos = Acoustic.chirpLength + Acoustic.gap
        let bins = F.bins
        func emit(_ xr: [Float], _ xi: [Float]) {
            var re = [Float](repeating: 0, count: Acoustic.N), im = re
            for (j, k) in bins.enumerated() {
                re[k] = xr[j]; im[k] = xi[j]
                re[Acoustic.N - k] = xr[j]; im[Acoustic.N - k] = -xi[j]
            }
            fft.transform(&re, &im, inverse: true)
            // fixed scale for unit average energy per carrier (≈0.22 RMS), so a symbol's level
            // doesn't depend on its data; windowed overlap-add
            let g = 0.22 / sqrt(2 * Float(bins.count))
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
        // reference (known QPSK phases on every carrier), then header as π flips of it
        let ref = Acoustic.referencePhases(band).map { Float($0) * .pi / 2 }
        emit(ref.map { cos($0) }, ref.map { sin($0) })
        let hdr = Acoustic.header(level: levelIndex, band: band)
        let off = ref.enumerated().map { $0.element + (hdr[$0.offset % 16] ? Float.pi : 0) }
        emit(off.map { cos($0) }, off.map { sin($0) })
        // data: constellation points rotated by each carrier's header phase; known phases on the pilots
        let con = Constellation(bits: b)
        var xr = [Float](repeating: 0, count: bins.count), xi = xr
        for s in 0..<F.symbols {
            for i in F.pilotPos { let a = Acoustic.pilotPhase(s, i); xr[i] = cos(a); xi[i] = sin(a) }
            bits.withUnsafeBufferPointer { bp in
                for (j, i) in F.dataPos.enumerated() {
                    let (pr, pi) = con.point(bits: bp.baseAddress! + (s * K + j) * b)
                    let c = cos(off[i]), sn = sin(off[i])
                    xr[i] = pr * c - pi * sn; xi[i] = pr * sn + pi * c
                }
            }
            emit(xr, xi)
        }
        for i in 0..<out.count { out[i] = max(-0.98, min(0.98, out[i])) }
        return out
    }
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
    public var syncs = 0
    /// Estimated channel capacity of the last frame, in bits per data carrier (from each
    /// carrier's measured noise), for judging whether a faster rate would get through.
    public var capacity: Double = 0
    /// Diagnostics for the last frame: mean decision margin (1 = perfect, 0 = on the boundary)
    public var carrierQuality: [Float] = []
    public var symbolQuality: [Float] = []
    /// Equalised symbols (re, im interleaved) and constellation decisions of the last frame (diagnostics)
    public var lastY: [Float] = []
    public var lastIdx: [Int] = []
}

public final class AcousticReceiver {
    public var bands: [AcousticBand] = AcousticBand.allCases
    public var threshold: Float = 0.15
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
                stats.syncs += 1
                pending = (band, p + Acoustic.chirpLength + Acoustic.gap + Acoustic.timingShift)
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
        let b = F.level.bits
        let K = F.K
        let con = Constellation(bits: b)
        // a channel estimate that rotates this far has slipped to a neighbouring constellation symmetry
        let slip: Float = b == 1 ? .pi / 2 : .pi / 4
        // Coherent detection with pilots. The channel on every carrier comes from the known
        // reference and header symbols; each data symbol's rotation (clock offset, Doppler,
        // movement) is measured on the pilots and removed before deciding.
        let bins = F.bins
        let nb = bins.count
        let ref = spectrum(at: start), hdr = spectrum(at: start + Acoustic.symbolLength)
        let refPh = Acoustic.referencePhases(F.band)
        let hdrBits = Acoustic.header(level: li, band: F.band)
        var h0r = [Float](repeating: 0, count: nb), h0i = h0r, hr = h0r, hi = h0r
        for (i, k) in bins.enumerated() {
            let a0 = Float(refPh[i]) * .pi / 2, a1 = a0 + (hdrBits[i % 16] ? .pi : 0)
            h0r[i] = ref.0[k] * cos(a0) + ref.1[k] * sin(a0); h0i[i] = ref.1[k] * cos(a0) - ref.0[k] * sin(a0)
            hr[i] = hdr.0[k] * cos(a1) + hdr.1[k] * sin(a1); hi[i] = hdr.1[k] * cos(a1) - hdr.0[k] * sin(a1)
        }
        let bc = Float(nb - 1) / 2
        /// θ(x) = a + c·(x − bc) fitted circularly to phases d at positions x (uniform spacing dx).
        func circularFit(_ d: [Float], _ w: [Float], _ x: [Int], _ dx: Float) -> (Float, Float) {
            var sr: Float = 0, si: Float = 0
            for j in 0..<(d.count - 1) {
                let ww = w[j] * w[j + 1], dd = d[j + 1] - d[j]
                sr += ww * cos(dd); si += ww * sin(dd)
            }
            let c = atan2(si, sr) / dx
            var ar: Float = 0, ai: Float = 0
            for j in 0..<d.count { let t = d[j] - c * (Float(x[j]) - bc); ar += w[j] * cos(t); ai += w[j] * sin(t) }
            return (atan2(ai, ar), c)
        }
        var hmag = (0..<nb).map { sqrt(hr[$0] * hr[$0] + hi[$0] * hi[$0]) }
        do {
            // align the reference-symbol estimate to the header symbol, then average the two
            let d = (0..<nb).map { atan2(hi[$0] * h0r[$0] - hr[$0] * h0i[$0], hr[$0] * h0r[$0] + hi[$0] * h0i[$0]) }
            let (a0, c0) = circularFit(d, hmag, Array(0..<nb), 1)
            for i in 0..<nb {
                let t = a0 + c0 * (Float(i) - bc), cs = cos(t), sn = sin(t)
                hr[i] = 0.5 * (hr[i] + h0r[i] * cs - h0i[i] * sn); hi[i] = 0.5 * (hi[i] + h0r[i] * sn + h0i[i] * cs)
            }
            hmag = (0..<nb).map { sqrt(hr[$0] * hr[$0] + hi[$0] * hi[$0]) }
        }
        var cq = [Float](repeating: 0, count: K), sq = [Float](repeating: 0, count: F.symbols)
        var dY = [Float](), dIdx = [Int]()
        let S = F.symbols, P = F.pilotPos.count
        // Pilot phases relative to the reference channel, for every symbol.
        let spectra = (0..<S).map { spectrum(at: start + ($0 + 2) * Acoustic.symbolLength) }
        var pzr = [[Float]](repeating: [Float](repeating: 0, count: P), count: S), pzi = pzr, pd = pzr
        for s in 0..<S {
            let cur = spectra[s]
            for (q, i) in F.pilotPos.enumerated() {
                let k = bins[i], a = Acoustic.pilotPhase(s, i)
                let zr = cur.0[k] * cos(a) + cur.1[k] * sin(a), zi = cur.1[k] * cos(a) - cur.0[k] * sin(a)
                pzr[s][q] = zr; pzi[s][q] = zi
                pd[s][q] = atan2(zi * hr[i] - zr * hi[i], zr * hr[i] + zi * hi[i])
            }
        }
        Acoustic.pilotDump?(pd, F.pilotPos.map { hmag[$0] }, F.pilotPos.map { bins[$0] })
        let px = F.pilotPos.map { Float($0) - bc }
        // Real speakers do not keep the channel the reference symbol saw: their DSP settles after
        // the silent gap, leaving a smooth frequency-dependent phase and gain change for the rest
        // of the frame. So the pilots, not the reference, define the channel the data sees.
        //
        // Clock offset: each pilot's phase advances at a steady rate ∝ its frequency. The rates
        // come from symbol-to-symbol differences (unambiguous, and blind to any static offset),
        // and a weighted straight-line fit across pilots gives the slope.
        var rate = [Float](repeating: 0, count: P), rw = rate
        for q in 0..<P {
            var sr: Float = 0, si: Float = 0
            for s in 1..<S { let d = pd[s][q] - pd[s - 1][q]; sr += cos(d); si += sin(d) }
            let c = min(0.99, sqrt(sr * sr + si * si) / Float(max(1, S - 1)))
            rate[q] = atan2(si, sr); rw[q] = c * c / (1 - c * c)
        }
        var slope: Float = 0
        do {
            var w = rw
            for _ in 0..<3 {   // reweight to shrug off pilots in notches
                var a: Float = 0, b: Float = 0, c: Float = 0, d: Float = 0, e: Float = 0
                for q in 0..<P { a += w[q]; b += w[q] * px[q]; c += w[q] * px[q] * px[q]; d += w[q] * rate[q]; e += w[q] * rate[q] * px[q] }
                let den = a * c - b * b
                guard den > 0 else { break }
                slope = (a * e - b * d) / den
                let icpt = (d - slope * b) / a
                for q in 0..<P { let r = (rate[q] - icpt - slope * px[q]) / 0.01; w[q] = rw[q] / (1 + r * r) }
            }
        }
        if !Acoustic.usePilotRotation { slope = 0 }
        // Per-symbol common phase a_s and each pilot's static offset θ_q, estimated alternately
        // (seeded from symbol-to-symbol differences).
        var rotA = [Float](repeating: 0, count: S), rotC = (0..<S).map { Float($0 + 1) * slope }
        var theta = [Float](repeating: 0, count: P), pq = rw
        if Acoustic.usePilotRotation {
            for s in 1..<S {
                var sr: Float = 0, si: Float = 0
                for q in 0..<P { let t = pd[s][q] - pd[s - 1][q] - slope * px[q]; sr += pq[q] * cos(t); si += pq[q] * sin(t) }
                rotA[s] = rotA[s - 1] + atan2(si, sr)
            }
            for _ in 0..<2 {
                for q in 0..<P {
                    var sr: Float = 0, si: Float = 0
                    for s in 0..<S { let t = pd[s][q] - rotA[s] - rotC[s] * px[q]; sr += cos(t); si += sin(t) }
                    theta[q] = atan2(si, sr)
                    let c = min(0.99, sqrt(sr * sr + si * si) / Float(S))
                    pq[q] = c * c / (1 - c * c)
                }
                for s in 0..<S {
                    var sr: Float = 0, si: Float = 0
                    for q in 0..<P { let t = pd[s][q] - rotC[s] * px[q] - theta[q]; sr += pq[q] * cos(t); si += pq[q] * sin(t) }
                    rotA[s] = atan2(si, sr)
                }
            }
        }
        if Acoustic.debugPilots {
            print(String(format: "  slope %+.2e/bin/sym (%.1f ppm)", slope, Double(slope) * Double(Acoustic.N) / (2 * .pi * Double(Acoustic.symbolLength)) * 1e6))
        }
        // Pilot channel: rotation-corrected pilot observations averaged over ±window symbols,
        // as a correction G = observed / reference channel.
        let window = Acoustic.pilotWindow
        var gr = [[Float]](repeating: [Float](repeating: 0, count: P), count: S), gi = gr
        do {
            var cr = [Float](repeating: 0, count: P), ci = cr
            var pre = [([Float], [Float])](repeating: (cr, ci), count: S + 1)
            for s in 0..<S {
                for (q, i) in F.pilotPos.enumerated() {
                    let t = rotA[s] + rotC[s] * px[q], ct = cos(t), st = sin(t)
                    let zr = pzr[s][q] * ct + pzi[s][q] * st, zi = pzi[s][q] * ct - pzr[s][q] * st
                    // divide by the reference channel
                    let h2 = max(1e-12, hr[i] * hr[i] + hi[i] * hi[i])
                    cr[q] += (zr * hr[i] + zi * hi[i]) / h2; ci[q] += (zi * hr[i] - zr * hi[i]) / h2
                }
                pre[s + 1] = (cr, ci)
            }
            for s in 0..<S {
                let lo = max(0, s - window), hi2 = min(S, s + window + 1), n = Float(hi2 - lo)
                for q in 0..<P { gr[s][q] = (pre[hi2].0[q] - pre[lo].0[q]) / n; gi[s][q] = (pre[hi2].1[q] - pre[lo].1[q]) / n }
            }
        }
        // interpolate G to every carrier from the nearest pilots, trusting steadier pilots more
        let sp = Acoustic.pilotSpacing
        let knownR = hr, knownI = hi
        var HR = [[Float]](repeating: hr, count: S), HI = HR
        for s in 0..<S {
            for i in 0..<nb {
                let q0 = i / sp
                var sr: Float = 0, si: Float = 0, sw: Float = 0
                for q in max(0, q0 - 1)...min(P - 1, q0 + 2) {
                    let d = abs(Float(F.pilotPos[q] - i))
                    let w = max(0, 1 - d / Float(2 * sp)) * (pq[q] + 0.05)
                    sr += w * gr[s][q]; si += w * gi[s][q]; sw += w
                }
                guard sw > 0 else { continue }
                sr /= sw; si /= sw
                HR[s][i] = knownR[i] * sr - knownI[i] * si
                HI[s][i] = knownR[i] * si + knownI[i] * sr
            }
        }
        let pilotHR = HR, pilotHI = HI
        // Iterative detection: decide every symbol, then refine each carrier's channel from
        // confident decisions within ±window symbols. The refinement is anchored to the pilot
        // channel and rejected if it swings by half a constellation step, so the decisions can't
        // talk themselves onto a rotated constellation.
        let off = (0..<nb).map { Float(refPh[$0]) * .pi / 2 + (hdrBits[$0 % 16] ? .pi : 0) }
        var dec = [[Int]](repeating: [Int](repeating: 0, count: K), count: S)
        var err = [[Float]](repeating: [Float](repeating: 0, count: K), count: S)
        var y = [[(Float, Float)]](repeating: [(Float, Float)](repeating: (0, 0), count: K), count: S)
        /// received symbol, equalised by the current channel estimate and rotated back to the constellation
        func equalise(_ s: Int, _ i: Int) -> (Float, Float) {
            let k = bins[i], cur = spectra[s]
            let gr = HR[s][i], gi = HI[s][i], g2 = max(1e-12, gr * gr + gi * gi)
            let yr = (cur.0[k] * gr + cur.1[k] * gi) / g2, yi = (cur.1[k] * gr - cur.0[k] * gi) / g2
            let t = -(rotA[s] + rotC[s] * (Float(i) - bc) + off[i]), c0 = cos(t), s0 = sin(t)
            return (yr * c0 - yi * s0, yr * s0 + yi * c0)
        }
        for pass in 0..<3 {
            for s in 0..<S {
                for (j, i) in F.dataPos.enumerated() {
                    let v = equalise(s, i)
                    y[s][j] = v
                    (dec[s][j], err[s][j]) = con.decide(v.0, v.1)
                }
            }
            if pass == 2 { break }
            // least-squares channel from confident decisions: Σ w·Z·conj(x) / Σ w·|x|²
            var cr = [[Float]](repeating: [Float](repeating: 0, count: K), count: S + 1), ci = cr, cw = cr
            for s in 0..<S {
                let cur = spectra[s]
                cr[s + 1] = cr[s]; ci[s + 1] = ci[s]; cw[s + 1] = cw[s]
                for (j, i) in F.dataPos.enumerated() {
                    let w = max(0, 1 - err[s][j])
                    if w < 0.3 { continue }
                    let (pr, pi) = con.point(dec[s][j])
                    let t = off[i] + rotA[s] + rotC[s] * (Float(i) - bc), c0 = cos(t), s0 = sin(t)
                    let xr = pr * c0 - pi * s0, xi = pr * s0 + pi * c0
                    let k = bins[i]
                    cr[s + 1][j] += w * (cur.0[k] * xr + cur.1[k] * xi); ci[s + 1][j] += w * (cur.1[k] * xr - cur.0[k] * xi)
                    cw[s + 1][j] += w * (pr * pr + pi * pi)
                }
            }
            let prior: Float = 3
            let window = Acoustic.decisionWindow
            for s in 0..<S {
                let lo = max(0, s - window), hi2 = min(S, s + window + 1)
                for (j, i) in F.dataPos.enumerated() {
                    let pr = pilotHR[s][i], pi = pilotHI[s][i]
                    let w = cw[hi2][j] - cw[lo][j]
                    let er = (cr[hi2][j] - cr[lo][j] + prior * pr) / (w + prior)
                    let ei = (ci[hi2][j] - ci[lo][j] + prior * pi) / (w + prior)
                    let swing = atan2(ei * pr - er * pi, er * pr + ei * pi)
                    if abs(swing) < slip { HR[s][i] = er; HI[s][i] = ei } else { HR[s][i] = pr; HI[s][i] = pi }
                }
            }
        }
        // Noise from the pilots: their spread around the known value (before equalising, where the
        // microphone's noise varies smoothly with frequency), interpolated and scaled by each
        // carrier's gain. Unlike the spread around decisions, this doesn't flatter a carrier
        // whose decisions are mostly wrong. It is tracked over ±3 symbols, because interference
        // such as speech comes in bursts: a burst then discounts only the symbols it hits.
        let noiseWindow = 3
        var pre = [[Float]](repeating: [Float](repeating: 0, count: P), count: S + 1)
        for s in 0..<S {
            pre[s + 1] = pre[s]
            for (q, i) in F.pilotPos.enumerated() {
                let t = rotA[s] + rotC[s] * px[q], ct = cos(t), st = sin(t)
                let zr = pzr[s][q] * ct + pzi[s][q] * st, zi = pzi[s][q] * ct - pzr[s][q] * st
                let er = zr - pilotHR[s][i], ei = zi - pilotHI[s][i]
                pre[s + 1][q] += er * er + ei * ei
            }
        }
        var floorNoise = [[Float]](repeating: [Float](repeating: 1, count: K), count: S)
        var floorMean = [Float](repeating: 0, count: K)
        for s in 0..<S {
            let lo = max(0, s - noiseWindow), hi2 = min(S, s + noiseWindow + 1), n = Float(hi2 - lo)
            for (j, i) in F.dataPos.enumerated() {
                let q0 = i / sp
                var sn: Float = 0, sw: Float = 0
                for q in max(0, q0 - 1)...min(P - 1, q0 + 2) {
                    let w = max(0, 1 - abs(Float(F.pilotPos[q] - i)) / Float(2 * sp))
                    sn += w * (pre[hi2][q] - pre[lo][q]) / n; sw += w
                }
                let g2 = max(1e-12, HR[s][i] * HR[s][i] + HI[s][i] * HI[s][i])
                if sw > 0 { floorNoise[s][j] = sn / sw / g2 }
                floorMean[j] += floorNoise[s][j] / Float(S)
            }
        }
        hmag = (0..<nb).map { i in
            var m: Float = 0
            for s in 0..<S { m += sqrt(HR[s][i] * HR[s][i] + HI[s][i] * HI[s][i]) }
            return m / Float(S)
        }
        // Soft bits from the equalised symbols. Each carrier's noise variance comes from its spread
        // around the decided points, so weak carriers contribute little to the decoder.
        var noise = [Float](repeating: 0, count: K)
        for s in 0..<S {
            for j in 0..<K {
                let (yr, yi) = y[s][j], (pr, pi) = con.point(dec[s][j])
                noise[j] += ((yr - pr) * (yr - pr) + (yi - pi) * (yi - pi)) / Float(S)
                let margin = max(0, 1 - err[s][j])
                cq[j] += margin / Float(S); sq[s] += margin / Float(K)
                dIdx.append(dec[s][j]); dY.append(yr); dY.append(yi)
            }
        }
        // a noise floor proportional to the constellation's spacing keeps any one carrier from
        // dominating the decoder
        let floor2 = 0.04 * con.half * con.half
        var llr = [Float](repeating: 0, count: S * K * b)
        var cap: Double = 0
        llr.withUnsafeMutableBufferPointer { lp in
            for s in 0..<S {
                for j in 0..<K {
                    // per-carrier level from the decisions, shaped over time by the pilots' noise
                    let f = floorNoise[s][j]
                    let n2 = max(floor2, f, noise[j] * f / max(1e-12, floorMean[j]))
                    con.llr(y[s][j].0, y[s][j].1, n2, into: lp.baseAddress! + (s * K + j) * b)
                    cap += log2(1 + 1 / Double(max(f, 1e-4)))
                }
            }
        }
        stats.capacity = cap / Double(S * K)
        // de-interleave, decode the convolutional code, then the Reed–Solomon packets
        let codedLLR = F.perm.map { llr[Int($0)] }
        let n = F.n
        let info = Convolutional.decode(codedLLR, info: F.slots * n * 8, rate: F.level.code)
        let infoRel: [Float] = F.level.code == .none ? codedLLR.map { abs($0) } : []
        var packets: [Packet] = []
        var corrections = 0
        for slot in 0..<F.slots {
            var cw = [UInt8](repeating: 0, count: n)
            var crel = [Float](repeating: 1, count: n)
            for i in 0..<n {
                var byte: UInt8 = 0
                var mr: Float = .greatestFiniteMagnitude
                for q in 0..<8 {
                    let bi = (slot * n + i) * 8 + q
                    byte = byte << 1 | info[bi]
                    if !infoRel.isEmpty { mr = min(mr, infoRel[bi]) }
                }
                cw[i] = byte ^ F.scramble[slot * n + i]
                if !infoRel.isEmpty { crel[i] = mr }
            }
            if let (p, c) = decodeCodeword(cw, crel, F) { packets.append(p); corrections += c }
        }
        stats.decoded = packets.count
        stats.corrections = corrections
        stats.carrierQuality = cq
        stats.lastY = dY; stats.lastIdx = dIdx
        stats.symbolQuality = sq
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
