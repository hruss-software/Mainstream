import AVFoundation
import Combine
import UIKit
import MainstreamCore

enum LinkMode: String, CaseIterable {
    case screen, sound, hidden
}

struct Received: Identifiable {
    let id = UUID()
    let payload: Payload
}

/// Receives over camera (visible or hidden codes, one or two cameras) or microphone,
/// and owns the camera for focus control and photos.
final class Receiver: NSObject, ObservableObject {
    @Published var progress: Double = 0
    @Published var active = false
    @Published var locked = false
    @Published var rate: Double = 0
    @Published var hint = 0
    @Published var received: Received?
    @Published var audioLevel: Float = 0
    @Published var micDenied = false
    @Published var heard = 0                  // acoustic sync preambles detected
    @Published var hiddenPreview: UIImage?    // demodulated hidden-code thumbnail
    @Published private(set) var multiCam = false
    @Published private(set) var dualActive = false
    @Published var lensPosition: Float = 0.5
    @Published private(set) var manualFocus = false

    static var multiCamSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    let preview = AVCaptureVideoPreviewLayer()
    let pipPreview = AVCaptureVideoPreviewLayer()
    private var session: AVCaptureSession?
    private var devices: [AVCaptureDevice] = []
    private var pipes: [CameraPipe] = []
    private var photoOutput: AVCapturePhotoOutput?
    private var photoDelegates: [PhotoDelegate] = []
    private let sessionQueue = DispatchQueue(label: "mainstream.session")
    private var running = false

    // shared decode state (ingestQueue only)
    fileprivate let ingestQueue = DispatchQueue(label: "mainstream.ingest", qos: .userInteractive)
    private let transfer = TransferDecoder()
    private var usefulTimes: [(TimeInterval, Int)] = []
    private var lastUseful: TimeInterval = 0
    private var lastLock: TimeInterval = 0
    private var lastPublish: TimeInterval = 0
    private var okEMA = 0.0, loadEMA = 0.0
    fileprivate var mode: LinkMode = .screen

    // audio
    private let engine = AVAudioEngine()
    private let acoustic = AcousticReceiver()
    private var converter: AVAudioConverter?
    private var listening = false
    private var wantListening = false
    private var lastTap: TimeInterval = 0
    private var watchdog: Timer?
    private var uiMode: LinkMode = .screen

    override init() {
        super.init()
        preview.videoGravity = .resizeAspectFill
        pipPreview.videoGravity = .resizeAspectFill
        // the audio engine stops when the session is reconfigured or interrupted; restart it
        let nc = NotificationCenter.default
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in self?.restartListening() }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let t = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if t == .ended { self?.restartListening() }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in self?.restartListening() }
    }

    // MARK: lifecycle

    func setMode(_ m: LinkMode) {
        uiMode = m
        ingestQueue.async { self.mode = m; self.transfer.reset(); self.usefulTimes.removeAll() }
        for p in pipes { p.resetHidden() }
        // sound mode turns the camera off so it can't take over the audio session
        sessionQueue.async { [self] in
            if m == .sound { session?.stopRunning() } else if running {
                if session == nil { build() }
                if let s = session, !s.isRunning { s.startRunning() }
            }
        }
        if m == .sound { startListening() } else { stopListening() }
        progress = 0
        active = false
        hiddenPreview = nil
    }

    func start(mode m: LinkMode) {
        sessionQueue.async { self.running = true }
        setMode(m)
    }

    func stop() {
        sessionQueue.async { [self] in
            running = false
            session?.stopRunning()
        }
        stopListening()
    }

    func reset() {
        ingestQueue.async { self.transfer.reset(); self.usefulTimes.removeAll() }
        progress = 0
        active = false
    }

    func setMultiCam(_ on: Bool) {
        guard on != multiCam else { return }
        multiCam = on
        sessionQueue.async { [self] in
            session?.stopRunning()
            build()
            if running { session?.startRunning() }
        }
    }

    // MARK: camera graph

    private func build() {
        if let old = session {
            old.beginConfiguration()
            for c in old.connections { old.removeConnection(c) }
            for i in old.inputs { old.removeInput(i) }
            for o in old.outputs { old.removeOutput(o) }
            old.commitConfiguration()
        }
        pipes = []
        devices = []
        photoOutput = nil
        if multiCam && Receiver.multiCamSupported, buildMulti() {
            DispatchQueue.main.async { self.dualActive = true }
            return
        }
        buildSingle()
        DispatchQueue.main.async { self.dualActive = false }
    }

    private func buildSingle() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let s = AVCaptureSession()
        s.automaticallyConfiguresApplicationAudioSession = false
        s.beginConfiguration()
        s.sessionPreset = .inputPriority
        if s.canAddInput(input) { s.addInput(input) }
        let pipe = CameraPipe(owner: self, index: 0)
        let out = pipe.makeOutput()
        if s.canAddOutput(out) { s.addOutput(out) }
        if let c = out.connection(with: .video), c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
        let photo = AVCapturePhotoOutput()
        if s.canAddOutput(photo) { s.addOutput(photo); photoOutput = photo }
        s.commitConfiguration()
        configure(device, formats: device.formats, cost: nil)
        pipe.frameInterval = device.activeVideoMinFrameDuration.seconds
        session = s
        devices = [device]
        pipes = [pipe]
        preview.session = s
        pipPreview.session = nil
    }

    /// Wide + ultra-wide (or telephoto) running together; both feed one transfer.
    private func buildMulti() -> Bool {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .back)
        let sets = discovery.supportedMultiCamDeviceSets
        func has(_ set: Set<AVCaptureDevice>, _ t: AVCaptureDevice.DeviceType) -> AVCaptureDevice? { set.first { $0.deviceType == t } }
        guard let set = sets.first(where: { has($0, .builtInWideAngleCamera) != nil && has($0, .builtInUltraWideCamera) != nil })
                ?? sets.first(where: { has($0, .builtInWideAngleCamera) != nil && $0.count >= 2 }),
              let wide = has(set, .builtInWideAngleCamera),
              let second = has(set, .builtInUltraWideCamera) ?? set.first(where: { $0 != wide }) else { return false }
        let s = AVCaptureMultiCamSession()
        s.automaticallyConfiguresApplicationAudioSession = false
        s.beginConfiguration()
        var ok = true
        var newPipes: [CameraPipe] = []
        for (i, dev) in [wide, second].enumerated() {
            guard let input = try? AVCaptureDeviceInput(device: dev), s.canAddInput(input) else { ok = false; break }
            s.addInputWithNoConnections(input)
            guard let port = input.ports(for: .video, sourceDeviceType: dev.deviceType, sourceDevicePosition: .back).first else { ok = false; break }
            let pipe = CameraPipe(owner: self, index: i)
            let out = pipe.makeOutput()
            guard s.canAddOutput(out) else { ok = false; break }
            s.addOutputWithNoConnections(out)
            let c = AVCaptureConnection(inputPorts: [port], output: out)
            guard s.canAddConnection(c) else { ok = false; break }
            s.addConnection(c)
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
            newPipes.append(pipe)
            let layer = i == 0 ? preview : pipPreview
            layer.setSessionWithNoConnection(s)
            let pc = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
            if s.canAddConnection(pc) { s.addConnection(pc) }
            if i == 0 {
                let photo = AVCapturePhotoOutput()
                if s.canAddOutput(photo) {
                    s.addOutputWithNoConnections(photo)
                    let ph = AVCaptureConnection(inputPorts: [port], output: photo)
                    if s.canAddConnection(ph) { s.addConnection(ph); photoOutput = photo }
                }
            }
        }
        // highest multi-cam formats the hardware budget allows
        if ok {
            for (dev, pipe) in zip([wide, second], newPipes) {
                configure(dev, formats: dev.formats.filter(\.isMultiCamSupported), cost: s)
                pipe.frameInterval = dev.activeVideoMinFrameDuration.seconds
            }
        }
        s.commitConfiguration()
        guard ok, s.hardwareCost <= 1 else {
            for c in s.connections { s.removeConnection(c) }
            preview.session = nil
            pipPreview.session = nil
            return false
        }
        session = s
        devices = [wide, second]
        pipes = newPipes
        return true
    }

    /// 60 fps at the highest resolution available (within the multi-cam budget), short
    /// exposures, near-range autofocus.
    private func configure(_ device: AVCaptureDevice, formats: [AVCaptureDevice.Format], cost: AVCaptureMultiCamSession?) {
        func fps(_ f: AVCaptureDevice.Format) -> Double { f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
        let candidates = formats.filter { f in
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return (sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                && d.width <= 4096 && fps(f) >= 29
        }.sorted { a, b in
            let pa = fps(a) >= 59 ? 1 : 0, pb = fps(b) >= 59 ? 1 : 0
            if pa != pb { return pa > pb }
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription), db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(da.width) * Int(da.height) > Int(db.width) * Int(db.height)
        }
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        for fmt in candidates {
            device.activeFormat = fmt
            if let s = cost, s.hardwareCost > 1 { continue }
            let rate = min(60, fps(fmt))
            let dur = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
            device.activeVideoMinFrameDuration = dur
            device.activeVideoMaxFrameDuration = dur
            break
        }
        let fmt = device.activeFormat
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        let maxExp = CMTime(value: 1, timescale: 250)
        if CMTimeCompare(maxExp, fmt.minExposureDuration) > 0 && CMTimeCompare(maxExp, fmt.maxExposureDuration) < 0 {
            device.activeMaxExposureDuration = maxExp
        }
        device.setExposureTargetBias(-0.7)
        if fmt.isVideoHDRSupported {
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = false
        }
    }

    // MARK: focus

    /// Tap-to-focus at a point in preview-layer coordinates (main thread).
    func focus(atLayerPoint p: CGPoint) {
        let dp = preview.captureDevicePointConverted(fromLayerPoint: p)
        manualFocus = false
        sessionQueue.async { [self] in
            for d in devices where (try? d.lockForConfiguration()) != nil {
                if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = dp }
                if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }
                if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = dp; d.exposureMode = .continuousAutoExposure }
                d.unlockForConfiguration()
            }
        }
    }

    /// Manual lens position 0 (closest) … 1 (farthest).
    func setLens(_ v: Float) {
        manualFocus = true
        lensPosition = v
        sessionQueue.async { [self] in
            for d in devices where d.isLockingFocusWithCustomLensPositionSupported && (try? d.lockForConfiguration()) != nil {
                d.setFocusModeLocked(lensPosition: v)
                d.unlockForConfiguration()
            }
        }
    }

    func continuousFocus() {
        manualFocus = false
        sessionQueue.async { [self] in
            for d in devices where (try? d.lockForConfiguration()) != nil {
                if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                d.unlockForConfiguration()
            }
        }
    }

    // MARK: photos

    func capturePhoto(_ done: @escaping (Data) -> Void) {
        sessionQueue.async { [self] in
            if session == nil { build() }
            guard let s = session, let out = photoOutput else { return }
            // the camera is off in sound mode: run it just long enough for the shot
            let wasRunning = s.isRunning
            if !wasRunning { s.startRunning(); Thread.sleep(forTimeInterval: 0.6) }
            let settings = out.availablePhotoCodecTypes.contains(.hevc)
                ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc]) : AVCapturePhotoSettings()
            if let c = out.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            let del = PhotoDelegate { [weak self] data, d in
                DispatchQueue.main.async {
                    self?.photoDelegates.removeAll { $0 === d }
                    if let data { done(data) }
                }
                if !wasRunning { self?.sessionQueue.async { if self?.uiMode == .sound { s.stopRunning() } } }
            }
            DispatchQueue.main.async { self.photoDelegates.append(del) }
            out.capturePhoto(with: settings, delegate: del)
        }
    }

    // MARK: microphone

    private func startListening() {
        wantListening = true
        if watchdog == nil {
            // restart the engine if taps stop arriving (route change, interruption, camera)
            watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, self.wantListening else { return }
                if !self.listening || CACurrentMediaTime() - self.lastTap > 1.5 { self.restartListening() }
            }
        }
        guard !listening else { return }
        AVAudioApplication.requestRecordPermission { ok in
            DispatchQueue.main.async {
                self.micDenied = !ok
                if ok { self.beginListening() }
            }
        }
    }

    private func restartListening() {
        guard wantListening, !micDenied else { return }
        if listening {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            listening = false
        }
        beginListening()
    }

    private func beginListening() {
        guard wantListening, !listening else { return }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
            try? s.setPreferredSampleRate(Acoustic.sampleRate)
            try s.setActive(true)
        } catch { return }
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Acoustic.sampleRate, channels: 1, interleaved: false)
        else { return }
        converter = inFmt.sampleRate == Acoustic.sampleRate && inFmt.channelCount == 1 ? nil : AVAudioConverter(from: inFmt, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buf, _ in
            guard let self else { return }
            self.lastTap = CACurrentMediaTime()
            var mono: AVAudioPCMBuffer = buf
            if let conv = self.converter {
                let cap = AVAudioFrameCount(Double(buf.frameLength) * Acoustic.sampleRate / inFmt.sampleRate) + 32
                guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
                var fed = false
                conv.convert(to: out, error: nil) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return buf
                }
                mono = out
            }
            guard let ch = mono.floatChannelData?[0] else { return }
            let n = Int(mono.frameLength)
            let samples = Array(UnsafeBufferPointer(start: ch, count: n))
            self.ingestQueue.async { self.ingestAudio(samples) }
        }
        engine.prepare()
        do {
            try engine.start()
            listening = true
            lastTap = CACurrentMediaTime()
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    private func stopListening() {
        wantListening = false
        watchdog?.invalidate()
        watchdog = nil
        guard listening else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        listening = false
        audioLevel = 0
    }

    private func ingestAudio(_ samples: [Float]) {
        let before = acoustic.stats.frames
        let syncBefore = acoustic.stats.syncs
        let packets = samples.withUnsafeBufferPointer { acoustic.process($0) }
        var peak: Float = 0
        for v in samples { peak = max(peak, abs(v)) }
        let st = acoustic.stats
        let gotFrame = st.frames != before
        let ok = st.slots > 0 ? Double(st.decoded) / Double(st.slots) : 0
        let load = st.decoded > 0 ? Double(st.corrections) / Double(st.decoded) / Double(max(1, st.parity / 2)) : 1
        if st.syncs != syncBefore { let n = st.syncs; DispatchQueue.main.async { self.heard = n } }
        absorb(packets, found: gotFrame, ok: ok, load: load, level: peak)
    }

    /// Small portrait thumbnail of the demodulated hidden signal, for aiming.
    fileprivate func publishHiddenPreview(_ img: DemodImage) {
        let step = max(1, img.width / 240)
        let w = img.width / step, h = img.height / step
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = ((y * step) * img.width + x * step) * 4, d = (y * w + x) * 4
                px[d] = img.bgra[s + 2]; px[d + 1] = img.bgra[s + 1]; px[d + 2] = img.bgra[s]
            }
        }
        guard let cg = cgImage(RGBAImage(width: w, height: h, pixels: px)) else { return }
        let ui = UIImage(cgImage: cg, scale: 1, orientation: .right)
        DispatchQueue.main.async { if self.uiMode == .hidden { self.hiddenPreview = ui } }
    }

    // MARK: shared ingest (ingestQueue)

    fileprivate func absorb(_ packets: [Packet], found: Bool, ok: Double, load: Double, level: Float? = nil) {
        let now = CACurrentMediaTime()
        var useful = 0
        for p in packets where transfer.ingest(p) { useful += 1 }
        if useful > 0 { usefulTimes.append((now, useful)); lastUseful = now }
        if found {
            lastLock = now
            okEMA = okEMA * 0.9 + ok * 0.1
            loadEMA = loadEMA * 0.9 + load * 0.1
        }
        usefulTimes.removeAll { now - $0.0 > 1.0 }
        if let done = transfer.takeResult() {
            usefulTimes.removeAll()
            DispatchQueue.main.async {
                self.progress = 1
                self.received = Received(payload: done)
                self.active = false
            }
            return
        }
        if now - lastPublish < 0.1 { return }
        lastPublish = now
        let prog = transfer.progress
        let r = Double(usefulTimes.reduce(0) { $0 + $1.1 } * Wire.symbolSize)
        let isActive = now - lastUseful < (mode == .sound ? 4 : 1.5) && transfer.session != nil
        let isLocked = now - lastLock < (mode == .sound ? 3 : 0.3)
        let h = !isLocked ? 0 : (okEMA > 0.97 && loadEMA < 0.25 ? 1 : (okEMA < 0.6 ? -1 : 0))
        DispatchQueue.main.async {
            if self.received != nil { return }
            self.progress = prog
            self.rate = r
            self.active = isActive
            self.locked = isLocked
            self.hint = h
            if let level { self.audioLevel = level }
            if !self.manualFocus, let d = self.devices.first { self.lensPosition = d.lensPosition }
        }
    }
}

/// One camera's decode path.
private final class CameraPipe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var owner: Receiver?
    let queue: DispatchQueue
    private let decodeQueue: DispatchQueue
    private let decoder = FrameDecoder()
    private let hiddenDecoder = FrameDecoder()
    private let demod = HiddenDemodulator()
    private var frames = 0
    private let busyLock = NSLock()
    private var busy = false
    private var lastThumb: TimeInterval = 0
    var frameInterval = 1.0 / 60

    init(owner: Receiver, index: Int) {
        self.owner = owner
        queue = DispatchQueue(label: "mainstream.video.\(index)", qos: .userInteractive)
        decodeQueue = DispatchQueue(label: "mainstream.hidden.\(index)", qos: .userInitiated)
        hiddenDecoder.bipolar = true
    }

    func makeOutput() -> AVCaptureVideoDataOutput {
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        return out
    }

    func resetHidden() { queue.async { self.demod.reset() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let owner, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let mode = owner.mode
        if mode == .sound { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let f = BGRAFrame(base: base.assumingMemoryBound(to: UInt8.self), width: CVPixelBufferGetWidth(pb),
                          height: CVPixelBufferGetHeight(pb), bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
        frames += 1
        if mode == .hidden {
            // keep this callback short: store the capture, and decode on another queue so
            // captures keep arriving every 1/60 s
            demod.push(f, time: CMSampleBufferGetPresentationTimeStamp(sb).seconds, frameInterval: frameInterval)
            busyLock.lock()
            let idle = !busy
            if idle && frames % 3 == 0 { busy = true }
            busyLock.unlock()
            guard idle && frames % 3 == 0 else { return }
            guard let img = demod.render() else { busyLock.lock(); busy = false; busyLock.unlock(); return }
            decodeQueue.async { [self] in
                let (packets, stats) = img.withFrame { hiddenDecoder.decode($0) }
                report(packets, stats)
                let now = CACurrentMediaTime()
                if now - lastThumb > 0.25 { lastThumb = now; owner.publishHiddenPreview(img) }
                busyLock.lock(); busy = false; busyLock.unlock()
            }
            return
        }
        let (packets, stats) = decoder.decode(f)
        report(packets, stats)
    }

    private func report(_ packets: [Packet], _ stats: FrameStats) {
        guard let owner else { return }
        let ok = stats.slots > 0 ? Double(stats.decoded) / Double(stats.slots) : 0
        let load = stats.decoded > 0 ? Double(stats.corrections) / Double(stats.decoded) / Double(max(1, stats.parity / 2)) : 1
        owner.ingestQueue.async { owner.absorb(packets, found: stats.found, ok: ok, load: load) }
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let done: (Data?, PhotoDelegate) -> Void
    init(_ done: @escaping (Data?, PhotoDelegate) -> Void) { self.done = done }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        done(photo.fileDataRepresentation(), self)
    }
}
