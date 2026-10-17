import Foundation

/// RGBA8 image.
public struct RGBAImage {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]
    public init(width: Int, height: Int, fill: UInt8 = 255) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: fill, count: width * height * 4)
    }
}

public enum Renderer {
    /// Renders one code frame at cell resolution (cols × rows RGBA). The header band is white;
    /// draw `headerImage` over it at pixel resolution.
    public static func frame(_ enc: TransferEncoder, layout L: FrameLayout) -> RGBAImage {
        var img = RGBAImage(width: L.cols, height: L.rows)
        img.pixels = L.template
        let ms = Wire.messageSize
        let n = L.n
        let bpc = L.level.bpc
        var msgs = [UInt8](repeating: 0, count: max(1, L.slots) * ms)
        msgs.withUnsafeMutableBufferPointer { enc.nextMessages(slots: L.slots, into: $0.baseAddress!) }
        // per-cell 3-bit values
        var vals = L.fill
        var cw = [UInt8](repeating: 0, count: n)
        L.dataCells.withUnsafeBufferPointer { cells in
            L.scramble.withUnsafeBufferPointer { sc in
                msgs.withUnsafeBufferPointer { mb in
                    cw.withUnsafeMutableBufferPointer { c in
                        for s in 0..<L.slots {
                            (c.baseAddress!).update(from: mb.baseAddress! + s * ms, count: ms)
                            L.rs.encode(UnsafePointer(c.baseAddress!), count: ms, parityOut: c.baseAddress! + ms)
                            for i in 0..<n { c[i] ^= sc[s * n + i] }
                            let base = s * L.cellsPerSlot
                            var cellBits = 0, cellIdx = 0, acc: UInt8 = 0
                            for i in 0..<n {
                                let byte = c[i]
                                for b in stride(from: 7, through: 0, by: -1) {
                                    acc |= ((byte >> UInt8(b)) & 1) << UInt8(cellBits)
                                    cellBits += 1
                                    if cellBits == bpc {
                                        vals[Int(cells[base + cellIdx])] = acc
                                        acc = 0; cellBits = 0; cellIdx += 1
                                    }
                                }
                            }
                            if cellBits > 0 {
                                let ci = Int(cells[base + cellIdx])
                                let pad = vals[ci] & ~((1 << UInt8(cellBits)) - 1)
                                vals[ci] = acc | pad
                            }
                        }
                    }
                }
            }
        }
        img.pixels.withUnsafeMutableBufferPointer { px in
            for ci in L.dataCells {
                let i = Int(ci)
                let v = vals[i]
                let (r, g, b) = color(v, bpc: bpc)
                px[i * 4] = r; px[i * 4 + 1] = g; px[i * 4 + 2] = b; px[i * 4 + 3] = 255
            }
        }
        return img
    }

    @inline(__always) static func color(_ v: UInt8, bpc: Int) -> (UInt8, UInt8, UInt8) {
        switch bpc {
        case 1:
            let c: UInt8 = v & 1 == 1 ? 255 : 0
            return (c, c, c)
        case 2:
            let g: UInt8 = v & 1 == 1 ? 255 : 0
            let rb: UInt8 = v & 2 == 2 ? 255 : 0
            return (rb, g, rb)
        default:
            return (v & 1 == 1 ? 255 : 0, v & 2 == 2 ? 255 : 0, v & 4 == 4 ? 255 : 0)
        }
    }

    /// Header band at pixel resolution: origin at cell (8m, 0), size ((cols-16m)·k, 7m·k).
    public static func headerImage(layout L: FrameLayout, cellPx k: Int) -> RGBAImage {
        let x0 = 8 * L.m * k
        let w = (L.cols - 16 * L.m) * k
        let h = 7 * L.m * k
        var img = RGBAImage(width: w, height: h)
        let bits = FrameLayout.headerPayload(level: L.levelIndex, aspect: L.aspectIndex)
        let fc = 3.5 * Double(L.m)
        let span = Double(L.cols) - 2 * fc
        let bw = (FrameLayout.headerS1 - FrameLayout.headerS0) / Double(FrameLayout.headerBits)
        var column = [Bool](repeating: false, count: w)
        for px in 0..<w {
            let xc = (Double(x0 + px) + 0.5) / Double(k)
            let s = (xc - fc) / span
            let bi = Int(floor((s - FrameLayout.headerS0) / bw))
            column[px] = bi >= 0 && bi < FrameLayout.headerBits && bits[bi]
        }
        for y in 0..<h {
            for x in 0..<w where column[x] {
                let o = (y * w + x) * 4
                img.pixels[o] = 0; img.pixels[o + 1] = 0; img.pixels[o + 2] = 0
            }
        }
        return img
    }

    /// Full pixel-resolution code image (frame scaled by k with header drawn in).
    public static func composite(layout L: FrameLayout, frame: RGBAImage, cellPx k: Int) -> RGBAImage {
        var out = RGBAImage(width: L.cols * k, height: L.rows * k)
        let W = out.width
        frame.pixels.withUnsafeBufferPointer { f in
            out.pixels.withUnsafeMutableBufferPointer { o in
                for y in 0..<out.height {
                    let cy = y / k
                    for x in 0..<W {
                        let si = (cy * L.cols + x / k) * 4
                        let di = (y * W + x) * 4
                        o[di] = f[si]; o[di + 1] = f[si + 1]; o[di + 2] = f[si + 2]; o[di + 3] = 255
                    }
                }
            }
        }
        let hdr = headerImage(layout: L, cellPx: k)
        let x0 = 8 * L.m * k
        for y in 0..<hdr.height {
            for x in 0..<hdr.width {
                let si = (y * hdr.width + x) * 4
                let di = (y * W + x0 + x) * 4
                out.pixels[di] = hdr.pixels[si]; out.pixels[di + 1] = hdr.pixels[si + 1]; out.pixels[di + 2] = hdr.pixels[si + 2]
            }
        }
        return out
    }
}
