import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import MainstreamCore

struct TextComposer: View {
    let onSend: (String) -> Void
    var onSendPayload: ((Payload) -> Void)? = nil
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            let t = text
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onSend(t) }
                        } label: { Image(systemName: "paperplane.fill") }
                        .disabled(text.isEmpty)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                    }
                    // paste text into the editor, or send a copied image straight away
                    ToolbarItem(placement: .primaryAction) {
                        PasteButton(supportedContentTypes: [.plainText, .image]) { providers in
                            guard let p = providers.first else { return }
                            if p.canLoadObject(ofClass: UIImage.self) {
                                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                                    guard let data else { return }
                                    let ext = p.registeredContentTypes.first { $0.conforms(to: .image) }?.preferredFilenameExtension ?? "png"
                                    DispatchQueue.main.async {
                                        dismiss()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onSendPayload?(Payload(kind: .image, name: "image.\(ext)", data: data)) }
                                    }
                                }
                            } else {
                                _ = p.loadObject(ofClass: String.self) { str, _ in
                                    if let str { DispatchQueue.main.async { text += str } }
                                }
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.circle)
                    }
                }
                .onAppear { focused = true }
        }
    }
}

final class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var recording = false
    @Published var level: Float = 0
    @Published var url: URL?
    @Published var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    func toggle() { recording ? stop() : start() }

    func start() {
        AVAudioApplication.requestRecordPermission { ok in
            guard ok else { return }
            DispatchQueue.main.async { self.begin() }
        }
    }

    private func begin() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? s.setActive(true)
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 32000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48000,
        ]
        guard let r = try? AVAudioRecorder(url: u, settings: settings) else { return }
        r.isMeteringEnabled = true
        r.record()
        recorder = r
        url = nil
        recording = true
        let start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder else { return }
            r.updateMeters()
            self.level = max(0, (r.averagePower(forChannel: 0) + 50) / 50)
            self.elapsed = Date().timeIntervalSince(start)
        }
    }

    func stop() {
        timer?.invalidate()
        recorder?.stop()
        url = recorder?.url
        recorder = nil
        recording = false
        level = 0
    }
}

struct AudioRecorderView: View {
    let onSend: (URL) -> Void
    @StateObject private var rec = Recorder()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Button { rec.toggle() } label: {
                ZStack {
                    Circle()
                        .fill(.red.opacity(0.18))
                        .frame(width: 132, height: 132)
                        .scaleEffect(1 + CGFloat(rec.level) * 0.35)
                        .animation(.easeOut(duration: 0.08), value: rec.level)
                    if rec.recording {
                        RoundedRectangle(cornerRadius: 8).fill(.red).frame(width: 40, height: 40)
                    } else {
                        Circle().fill(.red).frame(width: 76, height: 76)
                    }
                }
            }
            .buttonStyle(.plain)
            Text(Duration.seconds(rec.elapsed).formatted(.time(pattern: .minuteSecond)))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 48) {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.title2) }
                Button {
                    if let u = rec.url {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onSend(u) }
                    }
                } label: { Image(systemName: "paperplane.fill").font(.title2) }
                .disabled(rec.url == nil || rec.recording)
            }
            Spacer()
        }
        .onDisappear { if rec.recording { rec.stop() } }
    }
}

final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing = false
    @Published var position: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    init(data: Data) {
        super.init()
        player = try? AVAudioPlayer(data: data)
        player?.delegate = self
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); playing = false; timer?.invalidate(); return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        p.play()
        playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let p = self.player, p.duration > 0 else { return }
            self.position = p.currentTime / p.duration
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playing = false
        position = 0
        timer?.invalidate()
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        playing = false
    }
}
