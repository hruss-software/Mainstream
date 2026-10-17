import XCTest
@testable import MainstreamCore

/// Garbage in must never crash the receiver: noise frames, codes that are cropped, tiny or
/// skewed, random packets with valid checksums, and random Reed–Solomon input.
final class FuzzTests: XCTestCase {
    func testDecoderSurvivesHostileFrames() {
        var rng = SplitMix64(42)
        let fd = FrameDecoder()
        // pure noise, flat, and stripes at odd sizes
        for (w, h) in [(64, 48), (1920, 1080), (1080, 1920), (3840, 2160), (17, 9), (8, 8)] {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            for i in 0..<buf.count { buf[i] = UInt8(truncatingIfNeeded: rng.next()) }
            for pattern in 0..<3 {
                if pattern == 1 { for i in 0..<buf.count { buf[i] = 255 } }
                if pattern == 2 { for i in 0..<buf.count { buf[i] = (i / 4 / max(1, w / 64)) % 2 == 0 ? 0 : 255 } }
                _ = buf.withUnsafeBufferPointer { fd.decode(BGRAFrame(base: $0.baseAddress!, width: w, height: h, bytesPerRow: w * 4)) }
            }
        }
        // real codes under extreme geometry: off-frame, tiny, huge, rotated, skewed
        let enc = TransferEncoder(payload: Payload(kind: .file, name: "f", data: Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0) })))
        for li in [0, 6, 12] {
            guard let fit = Ladder.fit(level: li, width: 1146, height: 2322) else { continue }
            let L = FrameLayout.get(level: li, aspect: fit.aspect)
            let scr = Channel.screen(layout: L, frame: Renderer.frame(enc, layout: L), cellPx: fit.cellPx, screenW: 1206, screenH: 2622)
            for trial in 0..<10 {
                var p = ChannelParams()
                p.seed = rng.next()
                p.fill = [0.05, 0.2, 1.4, 2.5, 0.9][trial % 5]
                p.rotation = Double(trial) * 0.7
                p.tilt = trial % 2 == 0 ? 0.3 : 0.02
                p.offset = (Double(trial % 3 - 1) * 900, Double(trial % 4 - 2) * 500)
                p.blur = trial % 3 == 0 ? 6 : 0.8
                let cam = Channel.capture(scr, p)
                _ = cam.withUnsafeBufferPointer { fd.decode(BGRAFrame(base: $0.baseAddress!, width: p.camW, height: p.camH, bytesPerRow: p.camW * 4)) }
            }
        }
    }

    func testTransferSurvivesHostilePackets() {
        var rng = SplitMix64(7)
        let dec = TransferDecoder()
        var m = [UInt8](repeating: 0, count: Wire.messageSize)
        for i in 0..<20_000 {
            for j in 0..<m.count { m[j] = UInt8(truncatingIfNeeded: rng.next()) }
            m[0] = UInt8(i % 3)                           // data, meta and invalid types
            if i % 5 == 0 { m[Wire.headerSize] = UInt8(1 + i % 2) }   // plausible meta formats
            m.withUnsafeMutableBufferPointer { sealMessage($0.baseAddress!) }
            if let p = m.withUnsafeBufferPointer({ parseMessage($0.baseAddress!) }) { dec.ingest(p) }
        }
        // a meta announcing an absurd packed size must be refused, not allocated
        var meta = Meta(kind: .file, plan: BlockPlan(length: 1000), crc: 0, name: "x", packing: .lzma, originalLength: 1).encode()
        put32(&meta, 15, UInt32.max)
        XCTAssertNil(meta.withUnsafeBufferPointer { Meta.decode($0.baseAddress!) })
    }

    func testReedSolomonSurvivesGarbage() {
        var rng = SplitMix64(11)
        for parity in [32, 48, 64] {
            let rs = ReedSolomon(parity: parity)
            let n = Wire.messageSize + parity
            for _ in 0..<300 {
                var cw = (0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
                let er = (0..<Int(rng.next() % UInt64(parity + 8))).map { _ in Int(rng.next() % UInt64(n)) }
                _ = rs.decode(&cw, erasures: er)
            }
        }
    }
}
