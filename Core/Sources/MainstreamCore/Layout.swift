import Foundation

/// One rung of the rate ladder.
public struct Level: Sendable, Equatable {
    public let cols: Int        // cells across
    public let bpc: Int         // bits per cell (1 B/W, 2 green/magenta, 3 RGB)
    public let parity: Int      // RS parity bytes per packet
    public let hold: Int        // 60 Hz display refreshes per code frame
}

public enum Ladder {
    public static let levels: [Level] = [
        Level(cols: 80,  bpc: 1, parity: 32, hold: 1),
        Level(cols: 96,  bpc: 1, parity: 32, hold: 1),
        Level(cols: 88,  bpc: 2, parity: 32, hold: 1),
        Level(cols: 104, bpc: 2, parity: 32, hold: 1),
        Level(cols: 104, bpc: 3, parity: 32, hold: 1),
        Level(cols: 120, bpc: 3, parity: 32, hold: 1),
        Level(cols: 136, bpc: 3, parity: 32, hold: 1),
        Level(cols: 152, bpc: 3, parity: 40, hold: 1),
        Level(cols: 168, bpc: 3, parity: 40, hold: 1),
        Level(cols: 184, bpc: 3, parity: 48, hold: 1),
        Level(cols: 200, bpc: 3, parity: 48, hold: 1),
        Level(cols: 224, bpc: 3, parity: 56, hold: 1),
        Level(cols: 256, bpc: 3, parity: 64, hold: 1),
        Level(cols: 288, bpc: 3, parity: 64, hold: 1),
        Level(cols: 320, bpc: 3, parity: 64, hold: 1),
        // hidden-video levels (low-amplitude temporal modulation over a video)
        Level(cols: 52,  bpc: 3, parity: 48, hold: 1),
        Level(cols: 64,  bpc: 3, parity: 48, hold: 1),
        Level(cols: 80,  bpc: 3, parity: 48, hold: 1),
        Level(cols: 96,  bpc: 3, parity: 48, hold: 1),
    ]
    public static let visibleCount = 15
    public static let hiddenLevels = 15..<19
    public static var defaultIndex = 7
    /// rows / cols
    public static let aspects: [Double] = [1.0, 1.2, 1.35, 1.5, 1.65, 1.8, 1.95, 2.1]

    /// Chooses aspect index and pixel cell size for a sender canvas in physical pixels.
    public static func fit(level index: Int, width: Int, height: Int) -> (aspect: Int, cellPx: Int)? {
        let cols = levels[index].cols
        let k = width / cols
        guard k >= 2 else { return nil }
        var best: Int? = nil
        for (i, a) in aspects.enumerated() {
            let rows = Int((Double(cols) * a).rounded())
            if rows * k <= height { best = i }
        }
        guard let a = best else { return nil }
        return (a, k)
    }
}

enum CellKind: UInt8 { case data = 0, black = 1, white = 2, header = 3 }

public final class FrameLayout {
    public let levelIndex: Int
    public let aspectIndex: Int
    public let level: Level
    public let cols: Int
    public let rows: Int
    public let m: Int
    public let n: Int                 // codeword bytes
    let kind: [CellKind]
    let dataCells: [Int32]            // ordered cell indices
    public let slots: Int
    let cellsPerSlot: Int
    let scramble: [UInt8]             // slots * n
    let fill: [UInt8]                 // per-cell random bits for unused cells
    let template: [UInt8]             // RGBA cols*rows
    // alignment lattice
    let latX: [Double]
    let latY: [Double]
    let markerAt: [Bool]              // (latX.count * latY.count)
    let markerCX: [Double]            // marker centre per lattice column (cells)
    let markerCY: [Double]
    let rs: ReedSolomon

    static let headerS0 = 0.15
    static let headerS1 = 0.85
    static let headerBits = 24
    static let markerSpacing = 24.0
    static let bandRows = 24
    static let stripCols = 8

    private static var cache: [Int: FrameLayout] = [:]
    private static let lock = NSLock()

    public static func get(level: Int, aspect: Int) -> FrameLayout {
        let key = level * 16 + aspect
        lock.lock(); defer { lock.unlock() }
        if let l = cache[key] { return l }
        let l = FrameLayout(level: level, aspect: aspect)
        cache[key] = l
        return l
    }

    private init(level li: Int, aspect ai: Int) {
        levelIndex = li
        aspectIndex = ai
        level = Ladder.levels[li]
        cols = level.cols
        rows = Int((Double(cols) * Ladder.aspects[ai]).rounded())
        m = max(Ladder.hiddenLevels.contains(li) && cols >= 74 ? 2 : 1, Int((Double(cols) / 56).rounded()))
        n = Wire.messageSize + level.parity
        rs = ReedSolomon(parity: level.parity)

        var kind = [CellKind](repeating: .data, count: cols * rows)
        let cols = self.cols, rows = self.rows, m = self.m
        func set(_ x: Int, _ y: Int, _ k: CellKind) {
            if x >= 0 && y >= 0 && x < cols && y < rows { kind[y * cols + x] = k }
        }
        // Finders with white separators
        let f = 7 * m
        for (ox, oy) in [(0, 0), (cols - f, 0), (0, rows - f), (cols - f, rows - f)] {
            let sx = ox == 0 ? 0 : ox - m
            let sy = oy == 0 ? 0 : oy - m
            for y in sy..<(sy + 8 * m) { for x in sx..<(sx + 8 * m) { set(x, y, .white) } }
            for y in 0..<f {
                for x in 0..<f {
                    let r = max(abs(2 * x + 1 - f), abs(2 * y + 1 - f))  // in half-cells from center
                    let black = r < 3 * m || r >= 5 * m
                    set(ox + x, oy + y, black ? .black : .white)
                }
            }
        }
        // Header band
        for y in 0..<f { for x in (8 * m)..<(cols - 8 * m) { set(x, y, .header) } }
        // Alignment lattice
        let fc = 3.5 * Double(m)
        let nx = max(1, Int(((Double(cols) - 2 * fc) / FrameLayout.markerSpacing).rounded()))
        let ny = max(1, Int(((Double(rows) - 2 * fc) / FrameLayout.markerSpacing).rounded()))
        var lx = [Double](), ly = [Double]()
        var mcx = [Int](), mcy = [Int]()
        for i in 0...nx {
            let x = fc + Double(i) * (Double(cols) - 2 * fc) / Double(nx)
            let c = min(cols - 3, max(2, Int(x)))
            mcx.append(c)
            lx.append(i == 0 || i == nx ? x : Double(c) + 0.5)
        }
        for j in 0...ny {
            let y = fc + Double(j) * (Double(rows) - 2 * fc) / Double(ny)
            let c = min(rows - 3, max(2, Int(y)))
            mcy.append(c)
            ly.append(j == 0 || j == ny ? y : Double(c) + 0.5)
        }
        var markerAt = [Bool](repeating: false, count: lx.count * ly.count)
        for j in 0...ny {
            for i in 0...nx {
                let cx = mcx[i], cy = mcy[j]
                var free = true
                for y in (cy - 2)...(cy + 2) { for x in (cx - 2)...(cx + 2) where kind[y * cols + x] != .data { free = false } }
                guard free else { continue }
                markerAt[j * lx.count + i] = true
                for y in (cy - 2)...(cy + 2) {
                    for x in (cx - 2)...(cx + 2) {
                        let r = max(abs(x - cx), abs(y - cy))
                        set(x, y, r == 1 ? .white : .black)
                    }
                }
            }
        }
        latX = lx; latY = ly
        markerCX = mcx.map { Double($0) + 0.5 }
        markerCY = mcy.map { Double($0) + 0.5 }
        self.markerAt = markerAt
        self.kind = kind

        // Data order: bands of `bandRows`, each walked as `stripCols`-wide vertical strips,
        // raster inside a strip. A codeword then covers a roughly square patch, so tearing,
        // glare or a polarity flip only touches the codewords it actually crosses.
        var order = [Int32]()
        order.reserveCapacity(cols * rows)
        let BH = FrameLayout.bandRows, SW = FrameLayout.stripCols
        for by in stride(from: 0, to: rows, by: BH) {
            for sx in stride(from: 0, to: cols, by: SW) {
                for y in by..<min(rows, by + BH) {
                    for x in sx..<min(cols, sx + SW) where kind[y * cols + x] == .data {
                        order.append(Int32(y * cols + x))
                    }
                }
            }
        }
        dataCells = order
        cellsPerSlot = (8 * n + level.bpc - 1) / level.bpc
        slots = order.count / cellsPerSlot

        var rng = SplitMix64(0xC0FFEE ^ UInt64(li) << 8 ^ UInt64(ai))
        var sc = [UInt8](repeating: 0, count: slots * n)
        for i in 0..<sc.count { sc[i] = UInt8(truncatingIfNeeded: rng.next()) }
        scramble = sc
        var fl = [UInt8](repeating: 0, count: cols * rows)
        for i in 0..<fl.count { fl[i] = UInt8(truncatingIfNeeded: rng.next()) & 7 }
        fill = fl

        var tpl = [UInt8](repeating: 255, count: cols * rows * 4)
        for i in 0..<(cols * rows) where kind[i] == .black {
            tpl[i * 4] = 0; tpl[i * 4 + 1] = 0; tpl[i * 4 + 2] = 0
        }
        template = tpl
    }

    var finderCenters: [(Double, Double)] {
        let fc = 3.5 * Double(m)
        return [(fc, fc), (Double(cols) - fc, fc), (Double(cols) - fc, Double(rows) - fc), (fc, Double(rows) - fc)]
    }

    /// cell coords -> normalized (finder centres at unit square corners)
    @inline(__always) func normalized(_ x: Double, _ y: Double) -> (Double, Double) {
        let fc = 3.5 * Double(m)
        return ((x - fc) / (Double(cols) - 2 * fc), (y - fc) / (Double(rows) - 2 * fc))
    }

    static func headerPayload(level: Int, aspect: Int) -> [Bool] {
        let byte = UInt8(level << 3 | aspect)
        let crc = CRC16.compute([byte, 0x50])
        var bits = [Bool]()
        for i in (0..<8).reversed() { bits.append((byte >> UInt8(i)) & 1 == 1) }
        for i in (0..<16).reversed() { bits.append((crc >> UInt16(i)) & 1 == 1) }
        return bits
    }

    static func parseHeader(_ bits: [Bool]) -> (level: Int, aspect: Int)? {
        guard bits.count == headerBits else { return nil }
        var byte: UInt8 = 0
        for i in 0..<8 { byte = byte << 1 | (bits[i] ? 1 : 0) }
        var crc: UInt16 = 0
        for i in 8..<24 { crc = crc << 1 | (bits[i] ? 1 : 0) }
        guard CRC16.compute([byte, 0x50]) == crc else { return nil }
        let level = Int(byte >> 3), aspect = Int(byte & 7)
        guard level < Ladder.levels.count else { return nil }
        return (level, aspect)
    }

    /// Bits per second of payload if every packet arrives.
    public var nominalRate: Double {
        Double(slots - 1) * Double(Wire.symbolSize) * 60.0 / Double(level.hold)
    }
}
