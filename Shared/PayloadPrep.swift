import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import MainstreamCore

/// Bytes per second as a short label: 820 B/s, 2.4 kB/s, 1.3 MB/s.
func rateText(_ bps: Double) -> String { sizeText(bps) + "/s" }

/// Byte count as a short label: 820 B, 2.4 kB, 13 MB.
func sizeText(_ n: Double) -> String {
    if n < 999.5 { return "\(Int(n.rounded())) B" }
    if n < 999_500 { return String(format: n < 9_950 ? "%.1f kB" : "%.0f kB", n / 1000) }
    if n < 999_500_000 { return String(format: n < 9_950_000 ? "%.1f MB" : "%.0f MB", n / 1_000_000) }
    return String(format: "%.1f GB", n / 1_000_000_000)
}

enum PayloadPrep {
    static func type(of p: Payload) -> UTType? { UTType(filenameExtension: (p.name as NSString).pathExtension) }

    /// Kind from a file name, for files that arrive from pickers and the share sheet.
    static func kind(forName name: String) -> PayloadKind {
        guard let t = UTType(filenameExtension: (name as NSString).pathExtension) else { return .file }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .plainText) { return .text }
        return .file
    }

    static func isVideo(_ p: Payload) -> Bool { type(of: p)?.conforms(to: .movie) == true }

    /// A smaller version of a photo (HEIC, ≤2560 px, no location metadata) or video (960×540),
    /// or nil when the payload isn't media or wouldn't get meaningfully smaller.
    static func compressed(_ p: Payload) async -> Payload? {
        if p.kind == .image { return compressImage(p) }
        if isVideo(p) { return await compressVideo(p) }
        return nil
    }

    private static func compressImage(_ p: Payload) -> Payload? {
        guard p.data.count > 600_000, let src = CGImageSourceCreateWithData(p.data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake in the orientation
            kCGImageSourceThumbnailMaxPixelSize: 2560,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        for (type, ext, q) in [(UTType.heic, "heic", 0.6), (UTType.jpeg, "jpg", 0.7)] {
            let out = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            guard CGImageDestinationFinalize(dst) else { continue }
            guard out.length < p.data.count * 9 / 10 else { return nil }
            let base = (p.name as NSString).deletingPathExtension
            return Payload(kind: .image, name: "\(base.isEmpty ? "image" : base).\(ext)", data: out as Data)
        }
        return nil
    }

    private static func compressVideo(_ p: Payload) async -> Payload? {
        let dir = FileManager.default.temporaryDirectory
        let input = dir.appendingPathComponent("in-\(UUID().uuidString).\((p.name as NSString).pathExtension)")
        let output = dir.appendingPathComponent("out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        guard (try? p.data.write(to: input)) != nil,
              let session = AVAssetExportSession(asset: AVURLAsset(url: input), presetName: AVAssetExportPreset960x540) else { return nil }
        session.shouldOptimizeForNetworkUse = true
        if #available(iOS 18.0, *) {
            guard (try? await session.export(to: output, as: .mp4)) != nil else { return nil }
        } else {
            session.outputURL = output
            session.outputFileType = .mp4
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in session.exportAsynchronously { c.resume() } }
            guard session.status == .completed else { return nil }
        }
        guard let data = try? Data(contentsOf: output), data.count < p.data.count * 9 / 10 else { return nil }
        let base = (p.name as NSString).deletingPathExtension
        return Payload(kind: .file, name: "\(base.isEmpty ? "video" : base).mp4", data: data)
    }
}
