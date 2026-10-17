import SwiftUI
import AVFoundation
import MainstreamCore

/// Streams acoustic frames to the speaker, keeping two frames queued.
final class SoundPlayer: ObservableObject {
    @Published var level: Float = 0
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "mainstream.sound", qos: .userInteractive)
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Acoustic.sampleRate, channels: 1, interleaved: false)!
    private var encoder: TransferEncoder?
    private var tx: AcousticTransmitter?
    private var queued = 0
    private var running = false

    func start(payload: Payload, band: AcousticBand, level li: Int) {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default)
        try? s.setPreferredSampleRate(Acoustic.sampleRate)
        try? s.setActive(true)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }
        node.play()
        running = true
        queue.async { [self] in
            let enc = TransferEncoder(payload: payload)
            encoder = enc
            tx = AcousticTransmitter(encoder: enc, band: band, level: li)
            fill()
        }
    }

    func set(band: AcousticBand, level li: Int) {
        queue.async { [self] in
            guard let enc = encoder else { return }
            tx = AcousticTransmitter(encoder: enc, band: band, level: li)
        }
    }

    func stop() {
        running = false
        node.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// queue only
    private func fill() {
        while running, queued < 2, let tx {
            let samples = tx.nextFrame()
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            var peak: Float = 0
            for v in samples { peak = max(peak, abs(v)) }
            queued += 1
            node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { self.level = peak }
                self.queue.async { self.queued -= 1; self.fill() }
            }
        }
    }
}

struct SoundSender: View {
    let payload: Payload
    let onClose: () -> Void
    @StateObject private var player = SoundPlayer()
    @AppStorage("soundBand") private var bandRaw = AcousticBand.full.rawValue
    @AppStorage("soundLevel") private var level = Acoustic.defaultLevel
    @State private var pulse = false

    private var band: AcousticBand { AcousticBand(rawValue: bandRaw) ?? .full }
    /// stored value clamped, in case it came from an older, longer rate ladder
    private var rate: Int { min(max(0, level), Acoustic.levels.count - 1) }

    var body: some View {
        VStack(spacing: 0) {
            HStack { CloseButton(action: onClose); Spacer() }
            Spacer(minLength: 12)
            ZStack {
                Circle().fill(.white.opacity(0.06)).frame(width: 180, height: 180)
                    .scaleEffect(pulse ? 1.08 : 0.92)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.white)
            }
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
            Spacer(minLength: 24).frame(maxHeight: 56)
            controls
                .frame(maxWidth: 440)
            // keep the controls clear of the bottom edge
            Spacer(minLength: 48)
        }
        .padding(.horizontal, 22)
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear {
            pulse = true
            player.start(payload: payload, band: band, level: rate)
        }
        .onDisappear { player.stop() }
        .onChange(of: bandRaw) { _, _ in player.set(band: band, level: rate) }
        .onChange(of: level) { _, _ in player.set(band: band, level: rate) }
    }

    private var controls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 0) {
                ForEach([(AcousticBand.audible, "ear"), (.full, "waveform"), (.ultrasonic, "dog")], id: \.0) { b, icon in
                    Button { bandRaw = b.rawValue } label: {
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(band == b ? .white : .secondary)
                            .background(band == b ? Color.white.opacity(0.14) : .clear, in: Capsule())
                    }
                }
            }
            .padding(4)
            .background(.white.opacity(0.06), in: Capsule())
            VStack(spacing: 6) {
                IconSlider(value: Binding(get: { Double(rate) }, set: { level = Int($0) }),
                           range: 0...Double(Acoustic.levels.count - 1), low: "tortoise", high: "hare")
                Text(rateText(AcousticFrame.rate(band, rate)))
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .contentTransition(.numericText())
                    .animation(.default, value: rate)
            }
        }
    }
}
