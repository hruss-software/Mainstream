import SwiftUI
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers
import MainstreamCore

/// Plays a video with the code hidden in it: a low-opacity overlay that alternates between
/// the pattern and its complement every refresh (invisible to viewers, recovered by the camera).
final class HiddenView: UIView {
    private let playerLayer = AVPlayerLayer()
    private let overlay = CALayer()
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var link: CADisplayLink?
    private let producer = DispatchQueue(label: "mainstream.hidden", qos: .userInteractive)
    private let lock = NSLock()
    private var ready: [(CGImage, CGImage)] = []
    private var current: (CGImage, CGImage)?
    private var generation = 0
    private var producing = false
    private var encoder: TransferEncoder?
    private var job: (FrameLayout, Int)?
    private var tickCount = 0
    private var videoSize: CGSize?
    private var builtFor: (Int, CGSize, CGSize?)?

    var level = 2 { didSet { if level != oldValue { rebuild() } } }
    var strength: Float = 0.04 { didSet { overlay.opacity = strength } }

    init(payload: Payload, video: URL) {
        super.init(frame: .zero)
        backgroundColor = .black
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
        overlay.magnificationFilter = .nearest
        overlay.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull(), "opacity": NSNull()]
        overlay.opacity = strength
        layer.addSublayer(overlay)
        let item = AVPlayerItem(url: video)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
        Task { [weak self] in
            let asset = AVURLAsset(url: video)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, t) = try? await track.load(.naturalSize, .preferredTransform) else { return }
            let r = CGRect(origin: .zero, size: size).applying(t)
            await MainActor.run { self?.videoSize = CGSize(width: abs(r.width), height: abs(r.height)); self?.setNeedsLayout() }
        }
        producer.async { [weak self] in
            let enc = TransferEncoder(payload: payload)
            DispatchQueue.main.async { self?.encoder = enc; self?.rebuild() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { player.pause(); return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        if builtFor?.0 != level || builtFor?.1 != bounds.size || builtFor?.2 != videoSize { rebuild() }
    }

    private func rebuild() {
        guard encoder != nil, bounds.width > 0, let vs = videoSize, vs.width > 0 else { return }
        builtFor = (level, bounds.size, videoSize)
        let scale = traitCollection.displayScale
        let rect = AVMakeRect(aspectRatio: vs, insideRect: bounds)
        let landscape = rect.width > rect.height
        // fit the (portrait) code into the video rect, rotated for landscape video
        let longPx = Int((landscape ? rect.width : rect.height) * scale * 0.94)
        let shortPx = Int((landscape ? rect.height : rect.width) * scale * 0.94)
        let li = Ladder.hiddenLevels.lowerBound + min(level, Ladder.hiddenLevels.count - 1)
        var fitLevel = li
        var fit = Ladder.fit(level: fitLevel, width: shortPx, height: longPx)
        while fit == nil && fitLevel > Ladder.hiddenLevels.lowerBound { fitLevel -= 1; fit = Ladder.fit(level: fitLevel, width: shortPx, height: longPx) }
        guard let fit else { return }
        let L = FrameLayout.get(level: fitLevel, aspect: fit.aspect)
        let mg = Hidden.margin(layout: L, cellPx: fit.cellPx)
        let w = CGFloat(L.cols * fit.cellPx + 2 * mg) / scale, h = CGFloat(L.rows * fit.cellPx + 2 * mg) / scale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        overlay.transform = CATransform3DIdentity
        overlay.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        overlay.position = CGPoint(x: rect.midX.rounded(toPixel: scale), y: rect.midY.rounded(toPixel: scale))
        overlay.contentsScale = scale
        if landscape { overlay.transform = CATransform3DMakeRotation(.pi / 2, 0, 0, 1) }
        CATransaction.commit()
        lock.lock()
        generation += 1
        ready.removeAll()
        job = (L, fit.cellPx)
        lock.unlock()
        produce()
    }

    private func produce() {
        lock.lock()
        guard !producing, ready.count < 2, let (L, k) = job else { lock.unlock(); return }
        producing = true
        let gen = generation
        lock.unlock()
        producer.async { [weak self] in
            guard let self, let enc = self.encoder else { return }
            let p = Hidden.pattern(layout: L, frame: Renderer.frame(enc, layout: L), cellPx: k)
            let pair = cgImage(p).flatMap { a in cgImage(Hidden.complement(p)).map { (a, $0) } }
            self.lock.lock()
            if gen == self.generation, let pair { self.ready.append(pair) }
            self.producing = false
            self.lock.unlock()
            DispatchQueue.main.async { self.produce() }
        }
    }

    @objc private func tick() {
        if tickCount % Hidden.window == 0 || current == nil {
            lock.lock()
            if !ready.isEmpty { current = ready.removeFirst() }
            lock.unlock()
        }
        if let (p, q) = current {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlay.contents = tickCount % 2 == 0 ? p : q
            CATransaction.commit()
        }
        tickCount += 1
        produce()
    }
}

struct HiddenViewRep: UIViewRepresentable {
    let payload: Payload
    let video: URL
    let level: Int
    let strength: Double

    func makeUIView(context: Context) -> HiddenView { HiddenView(payload: payload, video: video) }

    func updateUIView(_ v: HiddenView, context: Context) {
        v.level = level
        v.strength = Float(strength)
    }
}

struct HiddenSender: View {
    let payload: Payload
    let video: URL
    let onClose: () -> Void
    @AppStorage("hiddenLevel") private var level = 2
    @AppStorage("hiddenStrength") private var strength = 0.04

    var body: some View {
        VStack(spacing: 0) {
            HStack { CloseButton(action: onClose); Spacer() }
            HiddenViewRep(payload: payload, video: video, level: level, strength: strength)
            VStack(spacing: 6) {
                IconSlider(value: Binding(get: { Double(level) }, set: { level = Int($0) }),
                           range: 0...Double(Ladder.hiddenLevels.count - 1), low: "square.grid.2x2", high: "square.grid.4x3.fill")
                IconSlider(value: $strength, range: 0.015...0.08, step: 0.005, low: "eye.slash", high: "eye")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }
}

/// A movie picked from Photos, copied to a temporary file.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: dst)
            return PickedMovie(url: dst)
        }
    }
}
