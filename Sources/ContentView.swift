import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import MainstreamCore

struct Outgoing: Identifiable {
    let id = UUID()
    let payload: Payload
}

struct ContentView: View {
    @StateObject private var rx = Receiver()
    @AppStorage("multiCam") private var multiCam = false
    @State private var outgoing: Outgoing?
    @State private var composing = false
    @State private var recording = false
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var flash = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            CameraPreview(layer: rx.preview) { rx.focus(atLayerPoint: $0) }
                .ignoresSafeArea()
            Color.black.opacity(rx.locked ? 0 : 0.25)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.25), value: rx.locked)
            Color.white.opacity(flash ? 0.8 : 0).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        ReceiveGauge(progress: rx.progress, rate: rx.rate, hint: rx.hint, active: rx.active)
                        if rx.dualActive {
                            PipPreview(layer: rx.pipPreview)
                                .frame(width: 84, height: 112)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                Spacer()
                HStack {
                    Spacer()
                    CameraControls(rx: rx, multiCam: $multiCam)
                }
                .padding(.trailing, 12)
                Spacer()
                HStack(spacing: 26) {
                    Button { composing = true } label: { icon("textformat") }
                    PhotosPicker(selection: $photo, matching: .images) { icon("photo") }
                    Button { shoot() } label: { icon("camera") }
                    Button { recording = true } label: { icon("mic") }
                    Button { importing = true } label: { icon("doc") }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            rx.setMultiCam(multiCam)
            rx.start()
            if let i = CommandLine.arguments.firstIndex(of: "-demoSend"), i + 1 < CommandLine.arguments.count {
                outgoing = Outgoing(payload: Payload(kind: .text, name: "text.txt", data: Data(CommandLine.arguments[i + 1].utf8)))
            }
        }
        .onChange(of: phase) { _, p in
            if p == .active && outgoing == nil && !recording { rx.start() } else if p != .active { rx.stop() }
        }
        .onChange(of: multiCam) { _, on in rx.setMultiCam(on) }
        // the receiver drops to one camera if the pair fails or overheats
        .onChange(of: rx.multiCam) { _, on in if !on && multiCam { multiCam = false } }
        .onChange(of: outgoing?.id) { _, id in if id != nil { rx.stop() } }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    send(Payload(kind: .image, name: "image.\(ext)", data: data))
                }
                photo = nil
            }
        }
        .sheet(isPresented: $composing) {
            TextComposer { send(Payload(kind: .text, name: "text.txt", data: Data($0.utf8))) }
        }
        .sheet(isPresented: $recording, onDismiss: { if outgoing == nil { rx.start() } }) {
            AudioRecorderView { url in
                if let d = try? Data(contentsOf: url) { send(Payload(kind: .audio, name: "audio.m4a", data: d)) }
            }
            .presentationDetents([.medium])
            .onAppear { rx.stop() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let d = try? Data(contentsOf: url) {
                let t = UTType(filenameExtension: url.pathExtension)
                let kind: PayloadKind = t?.conforms(to: .audio) == true ? .audio : t?.conforms(to: .image) == true ? .image : .file
                send(Payload(kind: kind, name: url.lastPathComponent, data: d))
            }
        }
        .fullScreenCover(item: $outgoing, onDismiss: { rx.start() }) { o in
            VisibleSender(payload: o.payload) { outgoing = nil }
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                Brightness.boost()
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                Brightness.restore()
            }
        }
        .sheet(item: $rx.received, onDismiss: { rx.reset() }) { r in
            ResultView(payload: r.payload)
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
    }

    private func shoot() {
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { withAnimation(.easeIn(duration: 0.2)) { flash = false } }
        rx.capturePhoto { data in send(Payload(kind: .image, name: "photo.heic", data: data)) }
    }

    private func send(_ p: Payload) {
        outgoing = Outgoing(payload: p)
    }
}

/// Vertical focus slider (top = far), auto-focus reset, and multi-camera toggle.
struct CameraControls: View {
    @ObservedObject var rx: Receiver
    @Binding var multiCam: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "mountain.2").font(.system(size: 13))
            Slider(value: Binding(get: { Double(rx.lensPosition) }, set: { rx.setLens(Float($0)) }), in: 0...1)
                .frame(width: 190)
                .rotationEffect(.degrees(-90))
                .frame(width: 30, height: 190)
            Image(systemName: "camera.macro").font(.system(size: 13))
            Button { rx.continuousFocus() } label: {
                Image(systemName: "viewfinder")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(rx.manualFocus ? .white : .yellow)
                    .frame(width: 36, height: 36)
            }
            if Receiver.multiCamSupported {
                Button { multiCam.toggle() } label: {
                    Image(systemName: "camera.on.rectangle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(multiCam ? .yellow : .white)
                        .frame(width: 36, height: 36)
                }
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

enum Brightness {
    private static var saved: CGFloat?
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }
    static func boost() {
        guard let s = screen else { return }
        saved = s.brightness
        s.brightness = 1
    }
    static func restore() {
        guard let v = saved, let s = screen else { return }
        s.brightness = v
        saved = nil
    }
}

/// Bytes per second as a short label: 820 B/s, 2.4 kB/s, 1.3 MB/s.
func rateText(_ bps: Double) -> String {
    if bps < 999.5 { return "\(Int(bps.rounded())) B/s" }
    if bps < 999_500 { return String(format: bps < 9_950 ? "%.1f kB/s" : "%.0f kB/s", bps / 1000) }
    return String(format: "%.1f MB/s", bps / 1_000_000)
}

/// Always-visible receive status: progress ring with percentage, live rate, and a chevron when a
/// denser or faster (↑) or a gentler (↓) setting on the sender would do better.
struct ReceiveGauge: View {
    let progress: Double
    let rate: Double
    let hint: Int
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(.white.opacity(0.2), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: max(0.002, progress))
                    .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.15), value: progress)
                Text("\(Int((progress * 100).rounded(.down)))")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
            .frame(width: 30, height: 30)
            HStack(spacing: 3) {
                Text(rateText(rate))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .frame(minWidth: 62, alignment: .leading)
                Image(systemName: hint > 0 ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(hint > 0 ? .green : .orange)
                    .opacity(hint == 0 ? 0 : 1)
            }
        }
        .foregroundStyle(.white.opacity(active ? 0.95 : 0.6))
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(height: 42)
        .background(.ultraThinMaterial, in: Capsule())
        .animation(.easeInOut(duration: 0.25), value: active)
    }
}

/// Hosts the receiver's preview layer; taps focus at that point.
struct CameraPreview: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    let onTap: (CGPoint) -> Void

    final class Host: UIView {
        var preview: AVCaptureVideoPreviewLayer?
        var onTap: ((CGPoint) -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            preview?.frame = bounds
            CATransaction.commit()
            if let c = preview?.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }
        @objc func tapped(_ g: UITapGestureRecognizer) {
            onTap?(g.location(in: self))
            let ring = CAShapeLayer()
            let p = g.location(in: self)
            ring.path = UIBezierPath(roundedRect: CGRect(x: p.x - 36, y: p.y - 36, width: 72, height: 72), cornerRadius: 8).cgPath
            ring.strokeColor = UIColor.systemYellow.cgColor
            ring.fillColor = nil
            ring.lineWidth = 1.5
            layer.addSublayer(ring)
            UIView.animate(withDuration: 0.6, delay: 0.4) { ring.opacity = 0 } completion: { _ in ring.removeFromSuperlayer() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ring.removeFromSuperlayer() }
        }
    }

    func makeUIView(context: Context) -> Host {
        let v = Host()
        v.backgroundColor = .black
        v.preview = layer
        v.onTap = onTap
        v.layer.addSublayer(layer)
        v.addGestureRecognizer(UITapGestureRecognizer(target: v, action: #selector(Host.tapped(_:))))
        return v
    }

    func updateUIView(_ v: Host, context: Context) { v.setNeedsLayout() }
}

struct PipPreview: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    final class Host: UIView {
        var preview: AVCaptureVideoPreviewLayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            preview?.frame = bounds
            if let c = preview?.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }
    }

    func makeUIView(context: Context) -> Host {
        let v = Host()
        v.backgroundColor = .black
        v.preview = layer
        v.layer.addSublayer(layer)
        return v
    }

    func updateUIView(_ v: Host, context: Context) { v.setNeedsLayout() }
}
