import Foundation

public enum PayloadKind: UInt8, Sendable {
    case text = 0, image = 1, audio = 2, file = 3
}

public struct Payload: Sendable {
    public var kind: PayloadKind
    public var name: String
    public var data: Data
    public init(kind: PayloadKind, name: String, data: Data) {
        self.kind = kind
        self.name = name
        self.data = data
    }
}

// Meta symbol: [0] format (1 raw, 2 packed) [1] kind [2-5] sent length [6-7] k [8-9] blocks
// [10-13] crc32 of the sent bytes; raw: [14] name length [15...] name;
// packed: [14] packing [15-18] original length [19] name length [20...] name.
struct Meta: Equatable {
    var kind: PayloadKind
    var plan: BlockPlan
    var crc: UInt32
    var name: String
    var packing: Packing = .none
    var originalLength = 0

    func encode() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: Wire.symbolSize)
        let packed = packing != .none
        b[0] = packed ? 2 : 1
        b[1] = kind.rawValue
        put32(&b, 2, UInt32(plan.length))
        put16(&b, 6, UInt16(plan.k))
        put16(&b, 8, UInt16(plan.blockCount))
        put32(&b, 10, crc)
        var o = 14
        if packed {
            b[14] = packing.rawValue
            put32(&b, 15, UInt32(originalLength))
            o = 19
        }
        var nameBytes = Array(name.utf8.prefix(Wire.symbolSize - o - 1))
        while String(bytes: nameBytes, encoding: .utf8) == nil && !nameBytes.isEmpty { nameBytes.removeLast() }
        b[o] = UInt8(nameBytes.count)
        for (i, c) in nameBytes.enumerated() { b[o + 1 + i] = c }
        return b
    }

    static func decode(_ b: UnsafePointer<UInt8>) -> Meta? {
        guard b[0] == 1 || b[0] == 2, let kind = PayloadKind(rawValue: b[1]) else { return nil }
        let len = Int(get32(b, 2))
        let k = Int(get16(b, 6))
        let blocks = Int(get16(b, 8))
        let plan = BlockPlan(length: len, blockCount: blocks, k: k)
        guard plan.isValid else { return nil }
        var o = 14
        var packing = Packing.none, original = len
        if b[0] == 2 {
            guard let p = Packing(rawValue: b[14]), p != .none else { return nil }
            packing = p
            original = Int(get32(b, 15))
            guard original > 0 && original <= Packing.maxExpanded else { return nil }
            o = 19
        }
        let nl = Int(b[o])
        guard nl <= Wire.symbolSize - o - 1 else { return nil }
        let name = String(decoding: UnsafeBufferPointer(start: b + o + 1, count: nl), as: UTF8.self)
        return Meta(kind: kind, plan: plan, crc: get32(b, 10), name: name, packing: packing, originalLength: original)
    }
}

@inline(__always) func put16(_ b: inout [UInt8], _ o: Int, _ v: UInt16) {
    b[o] = UInt8(v >> 8); b[o + 1] = UInt8(v & 0xff)
}
@inline(__always) func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    b[o] = UInt8(v >> 24); b[o + 1] = UInt8((v >> 16) & 0xff); b[o + 2] = UInt8((v >> 8) & 0xff); b[o + 3] = UInt8(v & 0xff)
}
@inline(__always) func get16(_ b: UnsafePointer<UInt8>, _ o: Int) -> UInt16 {
    UInt16(b[o]) << 8 | UInt16(b[o + 1])
}
@inline(__always) func get32(_ b: UnsafePointer<UInt8>, _ o: Int) -> UInt32 {
    UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
}

// Packet message (191 bytes, before RS parity):
// [0] type (0 data, 1 meta) [1-2] session [3-4] block [5-6] id [7..<187] payload [187..<191] crc32
public enum PacketType: UInt8, Sendable { case data = 0, meta = 1 }

public struct Packet: Sendable {
    public var type: PacketType
    public var session: UInt16
    public var block: Int
    public var id: Int
    public var payload: [UInt8]
}

func buildMessage(type: PacketType, session: UInt16, block: Int, id: Int, into m: UnsafeMutablePointer<UInt8>) {
    m[0] = type.rawValue
    m[1] = UInt8(session >> 8); m[2] = UInt8(session & 0xff)
    m[3] = UInt8((block >> 8) & 0xff); m[4] = UInt8(block & 0xff)
    m[5] = UInt8((id >> 8) & 0xff); m[6] = UInt8(id & 0xff)
}

func sealMessage(_ m: UnsafeMutablePointer<UInt8>) {
    let n = Wire.messageSize - 4
    let c = CRC32.compute(UnsafePointer(m), n)
    m[n] = UInt8(c >> 24); m[n + 1] = UInt8((c >> 16) & 0xff); m[n + 2] = UInt8((c >> 8) & 0xff); m[n + 3] = UInt8(c & 0xff)
}

func parseMessage(_ m: UnsafePointer<UInt8>) -> Packet? {
    let n = Wire.messageSize - 4
    guard CRC32.compute(m, n) == get32(m, n) else { return nil }
    guard let type = PacketType(rawValue: m[0]) else { return nil }
    return Packet(type: type, session: get16(m, 1), block: Int(get16(m, 3)), id: Int(get16(m, 5)),
                  payload: Array(UnsafeBufferPointer(start: m + Wire.headerSize, count: Wire.symbolSize)))
}

/// Produces the endless packet stream for one payload.
public final class TransferEncoder {
    public let session: UInt16
    public let payload: Payload
    let fountain: FountainEncoder
    let meta: [UInt8]
    private var counter = 0
    private var frameIndex = 0

    /// Bytes actually sent (after compression).
    public let sentBytes: Int

    public init(payload: Payload, session: UInt16 = UInt16.random(in: 1...UInt16.max), compress: Bool = true) {
        self.payload = payload
        self.session = session
        let original = [UInt8](payload.data)
        let packed = compress ? Packing.pack(original) : nil
        let bytes = packed?.1 ?? original
        sentBytes = bytes.count
        fountain = FountainEncoder(data: bytes, session: session)
        meta = Meta(kind: payload.kind, plan: fountain.plan, crc: CRC32.compute(bytes), name: payload.name,
                    packing: packed?.0 ?? .none, originalLength: original.count).encode()
    }

    public var plan: BlockPlan { fountain.plan }

    /// Fills `slots` messages (each messageSize bytes, contiguous) for the next frame.
    func nextMessages(slots: Int, into buf: UnsafeMutablePointer<UInt8>) {
        let ms = Wire.messageSize
        // metadata in every frame when frames are large, less often when they carry few packets
        let metaEvery = max(1, 12 / max(1, slots))
        let metaSlot = frameIndex % metaEvery == 0 && slots > 0 ? (frameIndex / metaEvery) % slots : -1
        frameIndex += 1
        let plan = fountain.plan
        for s in 0..<slots {
            let m = buf + s * ms
            if s == metaSlot {
                buildMessage(type: .meta, session: session, block: 0, id: 0, into: m)
                meta.withUnsafeBufferPointer { (m + Wire.headerSize).update(from: $0.baseAddress!, count: Wire.symbolSize) }
            } else {
                let block = counter % plan.blockCount
                let id = (counter / plan.blockCount) & 0xffff
                counter += 1
                buildMessage(type: .data, session: session, block: block, id: id, into: m)
                fountain.symbol(block: block, id: id, into: m + Wire.headerSize)
            }
            sealMessage(m)
        }
    }
}

/// Collects packets for one session and reassembles the payload.
public final class TransferDecoder {
    public private(set) var session: UInt16? = nil
    var meta: Meta? = nil
    private var blocks: [BlockDecoder] = []
    private var pending: [Packet] = []
    private var completedSessions: Set<UInt16> = []
    public private(set) var usefulPackets = 0
    public private(set) var result: Payload? = nil

    public init() {}

    public var progress: Double {
        guard let meta else { return 0 }
        let r = blocks.reduce(0) { $0 + $1.rank }
        return Double(r) / Double(meta.plan.totalSymbols)
    }

    public var expectedSize: Int? { meta?.plan.length }

    /// Returns true if the packet was useful (innovative).
    @discardableResult
    public func ingest(_ p: Packet) -> Bool {
        if completedSessions.contains(p.session) { return false }
        if p.type == .meta {
            guard let m = p.payload.withUnsafeBufferPointer({ Meta.decode($0.baseAddress!) }) else { return false }
            if session != p.session || meta == nil {
                session = p.session
                meta = m
                result = nil
                blocks = (0..<m.plan.blockCount).map { BlockDecoder(k: m.plan.symbols(in: $0)) }
                let queued = pending.filter { $0.session == p.session }
                pending.removeAll()
                usefulPackets = 0
                for q in queued { ingest(q) }
            }
            return false
        }
        guard let meta, session == p.session else {
            if pending.count < 4096 { pending.append(p) }
            return false
        }
        guard p.block < blocks.count else { return false }
        let ok = p.payload.withUnsafeBufferPointer {
            blocks[p.block].add(session: p.session, block: p.block, id: p.id, payload: $0.baseAddress!)
        }
        if ok {
            usefulPackets += 1
            if blocks.allSatisfy({ $0.isComplete }) { finish(meta) }
        }
        return ok
    }

    private func finish(_ meta: Meta) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(meta.plan.totalSymbols * Wire.symbolSize)
        for b in blocks { bytes += b.solved ?? [] }
        blocks = []
        // a wrong length, checksum or unpacking means a corrupt transfer: start this session over
        if bytes.count >= meta.plan.length {
            bytes.removeLast(bytes.count - meta.plan.length)
            if CRC32.compute(bytes) == meta.crc, let data = meta.packing.unpack(bytes, length: meta.originalLength) {
                if let s = session { completedSessions.insert(s) }
                result = Payload(kind: meta.kind, name: meta.name, data: Data(data))
                return
            }
        }
        self.meta = nil
        session = nil
    }

    public func takeResult() -> Payload? {
        defer { result = nil }
        return result
    }

    public func reset() {
        session = nil
        meta = nil
        blocks = []
        pending = []
        result = nil
        usefulPackets = 0
    }
}
