import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import LinkCore

struct Outgoing: Identifiable {
    let id = UUID()
    let payload: Payload
}

struct ContentView: View {
    @StateObject private var rx = Receiver()
    @State private var outgoing: Outgoing?
    @State private var composing = false
    @State private var recording = false
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            CameraPreview(session: rx.session)
                .ignoresSafeArea()
            Color.black.opacity(rx.locked ? 0 : 0.25)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.25), value: rx.locked)
            if rx.active {
                ReceiveGauge(progress: rx.progress, rate: rx.rate, hint: rx.hint)
                    .transition(.opacity)
            }
            VStack {
                Spacer()
                HStack(spacing: 34) {
                    Button { composing = true } label: { icon("textformat") }
                    PhotosPicker(selection: $photo, matching: .images) { icon("photo") }
                    Button { recording = true } label: { icon("waveform") }
                    Button { importing = true } label: { icon("doc") }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 12)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: rx.active)
        .preferredColorScheme(.dark)
        .onAppear {
            rx.start()
            if let i = CommandLine.arguments.firstIndex(of: "-demoSend"), i + 1 < CommandLine.arguments.count {
                send(Payload(kind: .text, name: "text.txt", data: Data(CommandLine.arguments[i + 1].utf8)))
            }
        }
        .onChange(of: phase) { _, p in p == .active && outgoing == nil ? rx.start() : rx.stop() }
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
        .sheet(isPresented: $recording) {
            AudioRecorderView { url in
                if let d = try? Data(contentsOf: url) { send(Payload(kind: .audio, name: "audio.m4a", data: d)) }
            }
            .presentationDetents([.medium])
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let d = try? Data(contentsOf: url) {
                let kind: PayloadKind = UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true ? .audio
                    : UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true ? .image : .file
                send(Payload(kind: kind, name: url.lastPathComponent, data: d))
            }
        }
        .fullScreenCover(item: $outgoing, onDismiss: { rx.start() }) { o in
            SenderScreen(payload: o.payload) { outgoing = nil }
                .ignoresSafeArea()
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

    private func send(_ p: Payload) {
        rx.stop()
        outgoing = Outgoing(payload: p)
    }
}

enum Brightness {
    private static var saved: CGFloat?
    static func boost() {
        guard let screen = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.screen }).first else { return }
        saved = screen.brightness
        screen.brightness = 1
    }
    static func restore() {
        guard let s = saved, let screen = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.screen }).first else { return }
        screen.brightness = s
        saved = nil
    }
}

struct ReceiveGauge: View {
    let progress: Double
    let rate: Double
    let hint: Int

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(.white.opacity(0.2), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.005, progress))
                    .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: progress)
            }
            .frame(width: 64, height: 64)
            HStack(spacing: 4) {
                if hint != 0 {
                    Image(systemName: hint > 0 ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                Text(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            if let c = preview.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
