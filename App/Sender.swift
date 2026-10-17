import SwiftUI
import UIKit
import PhotonCore

/// Full-screen animated code. Swipe up/down: density. Swipe left/right: frame rate.
final class SenderUIView: UIView {
    private let codeLayer = CALayer()
    private let headerLayer = CALayer()
    private let levelDots = UIStackView()
    private let rateDots = UIStackView()
    private let indicators = UIStackView()
    private var link: CADisplayLink?
    private let producer = DispatchQueue(label: "photon.render", qos: .userInteractive)
    private let lock = NSLock()
    private var ready: [(gen: Int, image: CGImage)] = []
    private var generation = 0
    private var producing = false
    private var encoder: TransferEncoder?
    private var layoutInfo: (FrameLayout, Int)?          // layout + cell px
    private var ticks = 0
    private var fadeWork: DispatchWorkItem?
    private static let maxHold = 6

    private(set) var level: Int = UserDefaults.standard.object(forKey: "level") as? Int ?? Ladder.defaultIndex
    private(set) var hold: Int = UserDefaults.standard.object(forKey: "hold") as? Int ?? 1

    var onClose: (() -> Void)?
    private let close = UIButton(type: .system)

    init(payload: Payload) {
        super.init(frame: .zero)
        backgroundColor = .white
        for l in [codeLayer, headerLayer] {
            l.magnificationFilter = .nearest
            l.minificationFilter = .nearest
            l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer.addSublayer(l)
        }
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        close.tintColor = .systemGray2
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        addSubview(close)
        for (s, n) in [(levelDots, Ladder.levels.count), (rateDots, SenderUIView.maxHold)] {
            s.axis = .horizontal
            s.spacing = 4
            for _ in 0..<n {
                let v = UIView()
                v.layer.cornerRadius = 2.5
                v.translatesAutoresizingMaskIntoConstraints = false
                v.widthAnchor.constraint(equalToConstant: 5).isActive = true
                v.heightAnchor.constraint(equalToConstant: 5).isActive = true
                s.addArrangedSubview(v)
            }
        }
        indicators.axis = .vertical
        indicators.alignment = .center
        indicators.spacing = 5
        indicators.addArrangedSubview(levelDots)
        indicators.addArrangedSubview(rateDots)
        indicators.alpha = 0
        addSubview(indicators)
        for (dir, act) in [(UISwipeGestureRecognizer.Direction.up, 0), (.down, 1), (.left, 2), (.right, 3)] {
            let g = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            g.direction = dir
            g.name = String(act)
            addGestureRecognizer(g)
        }
        producer.async { [weak self] in
            let enc = TransferEncoder(payload: payload)
            DispatchQueue.main.async { self?.encoder = enc; self?.rebuild() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            link?.invalidate()
            link = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = safeAreaInsets
        close.frame = CGRect(x: 8, y: max(4, s.top - 40), width: 36, height: 36)
        let sz = indicators.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        indicators.frame = CGRect(x: (bounds.width - sz.width) / 2, y: bounds.height - max(s.bottom, 20) + 2, width: sz.width, height: sz.height)
        rebuild()
    }

    @objc private func swiped(_ g: UISwipeGestureRecognizer) {
        switch g.name {
        case "0": level = min(Ladder.levels.count - 1, level + 1)
        case "1": level = max(0, level - 1)
        case "2": hold = min(SenderUIView.maxHold, hold + 1)
        default: hold = max(1, hold - 1)
        }
        UserDefaults.standard.set(level, forKey: "level")
        UserDefaults.standard.set(hold, forKey: "hold")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        rebuild()
        showIndicators()
    }

    private func showIndicators() {
        for (i, v) in levelDots.arrangedSubviews.enumerated() { v.backgroundColor = i <= level ? .systemGray : .systemGray5 }
        // more dots = faster frames
        for (i, v) in rateDots.arrangedSubviews.enumerated() { v.backgroundColor = i < SenderUIView.maxHold + 1 - hold ? .systemGray : .systemGray5 }
        indicators.alpha = 1
        fadeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in UIView.animate(withDuration: 0.4) { self?.indicators.alpha = 0 } }
        fadeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }

    private func rebuild() {
        guard encoder != nil, bounds.width > 0 else { return }
        let scale = traitCollection.displayScale
        let margin: CGFloat = 10
        let s = safeAreaInsets
        let avail = CGRect(x: margin, y: s.top + margin, width: bounds.width - 2 * margin,
                           height: bounds.height - s.top - max(s.bottom, 20) - 2 * margin)
        let wpx = Int(avail.width * scale), hpx = Int(avail.height * scale)
        var li = level
        var fit = Ladder.fit(level: li, width: wpx, height: hpx)
        while fit == nil && li > 0 { li -= 1; fit = Ladder.fit(level: li, width: wpx, height: hpx) }
        guard let fit else { return }
        let L = FrameLayout.get(level: li, aspect: fit.aspect)
        let k = fit.cellPx
        let wPt = CGFloat(L.cols * k) / scale, hPt = CGFloat(L.rows * k) / scale
        let x = (avail.midX - wPt / 2 * 1).rounded(toPixel: scale), y = (avail.midY - hPt / 2).rounded(toPixel: scale)
        codeLayer.frame = CGRect(x: x, y: y, width: wPt, height: hPt)
        let hdr = Renderer.headerImage(layout: L, cellPx: k)
        headerLayer.frame = CGRect(x: x + CGFloat(8 * L.m * k) / scale, y: y, width: CGFloat(hdr.width) / scale, height: CGFloat(hdr.height) / scale)
        headerLayer.contentsScale = scale
        headerLayer.contents = SenderUIView.cgImage(hdr)
        lock.lock()
        generation += 1
        ready.removeAll()
        layoutInfo = (L, k)
        lock.unlock()
        codeLayer.contents = nil
        produce()
    }

    private func produce() {
        lock.lock()
        if producing || ready.count >= 3 || layoutInfo == nil { lock.unlock(); return }
        producing = true
        let gen = generation
        let (L, _) = layoutInfo!
        lock.unlock()
        producer.async { [weak self] in
            guard let self, let enc = self.encoder else { return }
            let img = Renderer.frame(enc, layout: L)
            let cg = SenderUIView.cgImage(img)
            self.lock.lock()
            if gen == self.generation, let cg { self.ready.append((gen, cg)) }
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
                codeLayer.contents = next.image
                CATransaction.commit()
                ticks = 0
            }
        }
        produce()
    }

    static func cgImage(_ img: RGBAImage) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(img.pixels) as CFData) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4,
                       space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

private extension CGFloat {
    func rounded(toPixel scale: CGFloat) -> CGFloat { (self * scale).rounded() / scale }
}

struct SenderScreen: UIViewRepresentable {
    let payload: Payload
    let onClose: () -> Void

    func makeUIView(context: Context) -> SenderUIView {
        let v = SenderUIView(payload: payload)
        v.onClose = onClose
        return v
    }

    func updateUIView(_ uiView: SenderUIView, context: Context) {}
}
