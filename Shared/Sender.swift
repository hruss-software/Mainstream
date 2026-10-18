import SwiftUI
import UIKit
import MainstreamCore

/// Animated visible code filling its bounds. Density and frame rate are set from SwiftUI.
final class CodeView: UIView {
    private let codeLayer = CALayer()
    private let headerLayer = CALayer()
    private var link: CADisplayLink?
    private let producer = DispatchQueue(label: "mainstream.render", qos: .userInteractive)
    private let lock = NSLock()
    private var ready: [CGImage] = []
    private var generation = 0
    private var producing = false
    private var encoder: TransferEncoder?
    private var layoutInfo: FrameLayout?
    private var ticks = 0
    private var builtFor: (Int, CGSize)?

    var level = Ladder.defaultIndex { didSet { if level != oldValue { rebuild() } } }
    var hold = 1

    init(payload: Payload) {
        super.init(frame: .zero)
        backgroundColor = .white
        for l in [codeLayer, headerLayer] {
            l.magnificationFilter = .nearest
            l.minificationFilter = .nearest
            l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer.addSublayer(l)
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
        guard window != nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if builtFor?.0 != level || builtFor?.1 != bounds.size { rebuild() }
    }

    private func rebuild() {
        guard encoder != nil, bounds.width > 0 else { return }
        builtFor = (level, bounds.size)
        let scale = traitCollection.displayScale
        let avail = bounds.insetBy(dx: 10, dy: 10)
        let wpx = Int(avail.width * scale), hpx = Int(avail.height * scale)
        var li = min(level, Ladder.levels.count - 1)
        var fit = Ladder.fit(level: li, width: wpx, height: hpx)
        while fit == nil && li > 0 { li -= 1; fit = Ladder.fit(level: li, width: wpx, height: hpx) }
        guard let fit else { return }
        let L = FrameLayout.get(level: li, aspect: fit.aspect)
        let k = fit.cellPx
        let wPt = CGFloat(L.cols * k) / scale, hPt = CGFloat(L.rows * k) / scale
        let x = (avail.midX - wPt / 2).rounded(toPixel: scale), y = (avail.midY - hPt / 2).rounded(toPixel: scale)
        codeLayer.frame = CGRect(x: x, y: y, width: wPt, height: hPt)
        let hdr = Renderer.headerImage(layout: L, cellPx: k)
        headerLayer.frame = CGRect(x: x + CGFloat(8 * L.m * k) / scale, y: y, width: CGFloat(hdr.width) / scale, height: CGFloat(hdr.height) / scale)
        headerLayer.contentsScale = scale
        headerLayer.contents = cgImage(hdr)
        lock.lock()
        generation += 1
        ready.removeAll()
        layoutInfo = L
        lock.unlock()
        codeLayer.contents = nil
        produce()
    }

    private func produce() {
        lock.lock()
        guard !producing, ready.count < 3, let L = layoutInfo else { lock.unlock(); return }
        producing = true
        let gen = generation
        lock.unlock()
        producer.async { [weak self] in
            guard let self, let enc = self.encoder else { return }
            let cg = cgImage(Renderer.frame(enc, layout: L))
            self.lock.lock()
            if gen == self.generation, let cg { self.ready.append(cg) }
            self.producing = false
            self.lock.unlock()
            DispatchQueue.main.async { self.produce() }
        }
    }

    @objc private func tick() {
        ticks += 1
        if ticks >= hold || codeLayer.contents == nil {
            lock.lock()
            let next = ready.isEmpty ? nil : ready.removeFirst()
            lock.unlock()
            if let next {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                codeLayer.contents = next
                CATransaction.commit()
                ticks = 0
            }
        }
        produce()
    }
}

func cgImage(_ img: RGBAImage) -> CGImage? {
    let cs = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    guard let provider = CGDataProvider(data: Data(img.pixels) as CFData) else { return nil }
    return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4,
                   space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

extension CGFloat {
    func rounded(toPixel scale: CGFloat) -> CGFloat { (self * scale).rounded() / scale }
}

struct CodeViewRep: UIViewRepresentable {
    let payload: Payload
    let level: Int
    let hold: Int

    func makeUIView(context: Context) -> CodeView { CodeView(payload: payload) }

    func updateUIView(_ v: CodeView, context: Context) {
        v.hold = hold
        v.level = level
    }
}

/// Icon – slider – icon row.
struct IconSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let low: String
    let high: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: low).frame(width: 24)
            Slider(value: $value, in: range, step: step)
            Image(systemName: high).frame(width: 24)
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

struct VisibleSender: View {
    let payload: Payload
    let onClose: () -> Void
    @AppStorage("level") private var level = Ladder.defaultIndex
    @AppStorage("hold") private var hold = 1
    @AppStorage("compressMedia") private var compressMedia = true
    @State private var small: Payload?        // compressed photo or video, when it is smaller
    @State private var ready = false

    private var sending: Payload { compressMedia ? (small ?? payload) : payload }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CloseButton(action: onClose)
                Spacer()
                if small != nil {
                    // send the smaller re-encoded photo/video, or the original
                    Button { compressMedia.toggle() } label: {
                        Image(systemName: compressMedia ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 40, height: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(compressMedia ? Color.accentColor : .secondary)
                    .accessibilityLabel("Send smaller version")
                    .accessibilityAddTraits(compressMedia ? .isSelected : [])
                }
                Text(sizeText(Double(sending.data.count)))
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 16)
            }
            if ready {
                CodeViewRep(payload: sending, level: level, hold: hold)
                    .id(compressMedia && small != nil)      // a different payload is a new transfer
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(spacing: 6) {
                IconSlider(value: Binding(get: { Double(level) }, set: { level = Int($0) }),
                           range: 0...Double(Ladder.levels.count - 1), low: "square.grid.2x2", high: "square.grid.4x3.fill")
                    .accessibilityLabel("Density")
                    .sensoryFeedback(.selection, trigger: level)
                // right = faster frames
                IconSlider(value: Binding(get: { Double(7 - hold) }, set: { hold = 7 - Int($0) }),
                           range: 1...6, low: "tortoise", high: "hare")
                    .accessibilityLabel("Frame rate")
                    .sensoryFeedback(.selection, trigger: hold)
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .background(Color.white.ignoresSafeArea())
        .environment(\.colorScheme, .light)
        .task {
            small = await PayloadPrep.compressed(payload)
            ready = true
        }
    }
}
