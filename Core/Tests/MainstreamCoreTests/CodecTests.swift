import XCTest
@testable import MainstreamCore

final class CodecTests: XCTestCase {
    func testReedSolomonErrorsAndErasures() {
        var rng = SplitMix64(42)
        for parity in [16, 32, 48, 64] {
            let rs = ReedSolomon(parity: parity)
            for trial in 0..<300 {
                let k = Wire.messageSize
                let msg = (0..<k).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
                let cw = rs.encode(msg)
                let n = cw.count
                var syn = cw
                XCTAssertEqual(rs.decode(&syn), 0)
                let f = Int(rng.next() % UInt64(parity / 2 + 1))
                let maxE = (parity - f) / 2
                let e = Int(rng.next() % UInt64(maxE + 1))
                var pos = Array(0..<n)
                for i in 0..<(f + e) { let j = i + Int(rng.next() % UInt64(n - i)); pos.swapAt(i, j) }
                var bad = cw
                for i in 0..<(f + e) { bad[pos[i]] ^= UInt8(truncatingIfNeeded: rng.next() | 1) }
                // some erasures may hit unchanged positions too
                let er = Array(pos[0..<f])
                let r = rs.decode(&bad, erasures: er)
                XCTAssertNotNil(r, "parity \(parity) trial \(trial) f \(f) e \(e)")
                XCTAssertEqual(bad, cw)
            }
            // beyond capacity should (almost always) fail rather than miscorrect silently
            var fails = 0
            for _ in 0..<50 {
                let msg = (0..<Wire.messageSize).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
                let cw = rs.encode(msg)
                var bad = cw
                for i in 0..<(parity / 2 + 3) { bad[i * 3] ^= 0x5a }
                if rs.decode(&bad) == nil || bad != cw { fails += 1 }
            }
            XCTAssertEqual(fails, 50)
        }
    }

    func testFountainRoundTrip() {
        var rng = SplitMix64(7)
        for size in [1, 179, 180, 181, 5000, 200_000, 400_000] {
            let data = (0..<size).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            let enc = TransferEncoder(payload: Payload(kind: .file, name: "x.bin", data: Data(data)))
            let dec = TransferDecoder()
            var buf = [UInt8](repeating: 0, count: 64 * Wire.messageSize)
            var frames = 0
            var sent = 0
            while dec.result == nil && frames < 100_000 {
                buf.withUnsafeMutableBufferPointer { enc.nextMessages(slots: 64, into: $0.baseAddress!) }
                frames += 1
                for s in 0..<64 {
                    // 30% loss
                    if rng.next() % 10 < 3 { continue }
                    let p = buf.withUnsafeBufferPointer { parseMessage($0.baseAddress! + s * Wire.messageSize) }!
                    if p.type == .data { sent += 1 }
                    dec.ingest(p)
                }
            }
            XCTAssertEqual(dec.result?.data, Data(data), "size \(size)")
            let plan = BlockPlan(length: size)
            let overhead = Double(sent) / Double(plan.totalSymbols)
            print("size \(size) symbols \(plan.totalSymbols) blocks \(plan.blockCount) received/needed \(String(format: "%.3f", overhead))")
        }
    }

    func testLayouts() {
        for li in 0..<Ladder.levels.count {
            for ai in 0..<Ladder.aspects.count {
                let L = FrameLayout.get(level: li, aspect: ai)
                XCTAssertGreaterThan(L.slots, 1, "level \(li) aspect \(ai)")
                XCTAssertEqual(FrameLayout.parseHeader(FrameLayout.headerPayload(level: li, aspect: ai))?.level, li)
            }
            let L = FrameLayout.get(level: li, aspect: 6)
            print("level \(li) cols \(L.cols) rows \(L.rows) m \(L.m) slots \(L.slots) markers \(L.markerAt.filter { $0 }.count) nominal \(Int(L.nominalRate / 1000)) kB/s")
        }
    }

    func testEndToEndSyntheticCamera() {
        var rng = SplitMix64(99)
        let data = (0..<30_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let enc = TransferEncoder(payload: Payload(kind: .image, name: "a.jpg", data: Data(data)))
        let dec = TransferDecoder()
        let fd = FrameDecoder()
        let li = 5
        guard let fit = Ladder.fit(level: li, width: 1206 - 60, height: 2622 - 300) else { return XCTFail() }
        let L = FrameLayout.get(level: li, aspect: fit.aspect)
        var params = ChannelParams()
        var frames = 0
        while dec.result == nil && frames < 40 {
            let fr = Renderer.frame(enc, layout: L)
            let scr = Channel.screen(layout: L, frame: fr, cellPx: fit.cellPx, screenW: 1206, screenH: 2622)
            params.seed = UInt64(frames + 1)
            let cam = Channel.capture(scr, params)
            let (pk, st) = cam.withUnsafeBufferPointer {
                fd.decode(BGRAFrame(base: $0.baseAddress!, width: params.camW, height: params.camH, bytesPerRow: params.camW * 4))
            }
            print("frame \(frames) found \(st.found) level \(String(describing: st.levelIndex)) decoded \(st.decoded)/\(st.slots) corr \(st.corrections) markers \(st.markersFound)/\(st.markersTotal)")
            for p in pk { dec.ingest(p) }
            frames += 1
        }
        XCTAssertEqual(dec.result?.data, Data(data))
    }
}

final class ChannelTests: XCTestCase {
    func testAcousticRoundTrip() {
        var rng = SplitMix64(5)
        let data = Data((0..<3000).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        for band in AcousticBand.allCases {
            let enc = TransferEncoder(payload: Payload(kind: .file, name: "s.bin", data: data))
            let tx = AcousticTransmitter(encoder: enc, band: band, level: 1)
            let rx = AcousticReceiver()
            let td = TransferDecoder()
            var room = RoomParams()
            room.snrDB = 22
            if band != .full { room.highCut = 22_000 }
            var frames = 0
            while td.result == nil && frames < 80 {
                room.seed = UInt64(frames + 1)
                let heard = Room.apply([Float](repeating: 0, count: 777) + tx.nextFrame(), room)
                heard.withUnsafeBufferPointer { for p in rx.process($0) { td.ingest(p) } }
                frames += 1
            }
            XCTAssertEqual(td.result?.data, data, "\(band)")
        }
    }

    /// Every rate, including the QAM ones, through a clean room on the whole-range band.
    func testAcousticAllLevels() {
        var rng = SplitMix64(9)
        let data = Data((0..<6000).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        for li in 0..<Acoustic.levels.count {
            let tx = AcousticTransmitter(encoder: TransferEncoder(payload: Payload(kind: .file, name: "q.bin", data: data)), band: .full, level: li)
            let rx = AcousticReceiver()
            let td = TransferDecoder()
            var room = RoomParams()
            room.snrDB = 35
            var frames = 0
            while td.result == nil && frames < 40 {
                room.seed = UInt64(frames + 1)
                let heard = Room.apply([Float](repeating: 0, count: 500) + tx.nextFrame(), room)
                heard.withUnsafeBufferPointer { for p in rx.process($0) { td.ingest(p) } }
                frames += 1
            }
            XCTAssertEqual(td.result?.data, data, "level \(li)")
        }
    }

    func testConstellations() {
        for bits in [1, 2, 4, 6] {
            let c = Constellation(bits: bits)
            var energy: Float = 0
            for idx in 0..<(1 << bits) {
                let (r, i) = c.point(idx)
                energy += r * r + i * i
                // a clean point decides to itself and its soft bits have the right signs
                var l = [Float](repeating: 0, count: bits)
                l.withUnsafeMutableBufferPointer { c.llr(r, i, 0.01, into: $0.baseAddress!) }
                let back = l.reduce(0) { $0 << 1 | ($1 < 0 ? 1 : 0) }
                XCTAssertEqual(back, idx, "bits \(bits) idx \(idx)")
            }
            XCTAssertEqual(energy / Float(1 << bits), 1, accuracy: 1e-4, "bits \(bits)")
        }
    }
}
