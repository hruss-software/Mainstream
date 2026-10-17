import AVFoundation
import Combine
import LinkCore

struct Received: Identifiable {
    let id = UUID()
    let payload: Payload
}

/// Camera capture + decoding. Publishes progress on the main thread.
final class Receiver: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var progress: Double = 0
    @Published var active = false
    @Published var locked = false
    @Published var rate: Double = 0          // payload bytes / s
    @Published var expected: Int = 0
    @Published var hint = 0                  // +1 denser possible, -1 too dense
    @Published var received: Received?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "link.session")
    private let videoQueue = DispatchQueue(label: "link.video", qos: .userInteractive)
    private var configured = false

    // video-queue state
    private let frameDecoder = FrameDecoder()
    private let transfer = TransferDecoder()
    private var usefulTimes: [(TimeInterval, Int)] = []
    private var lastUseful: TimeInterval = 0
    private var lastLock: TimeInterval = 0
    private var lastPublish: TimeInterval = 0
    private var okEMA = 0.0, loadEMA = 0.0

    func start() {
        sessionQueue.async { [self] in
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func reset() {
        videoQueue.async { [self] in
            transfer.reset()
            usefulTimes.removeAll()
        }
        progress = 0
        active = false
    }

    private func configure() {
        configured = true
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
        guard let device = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices.first,
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let c = output.connection(with: .video), c.isVideoStabilizationSupported {
            c.preferredVideoStabilizationMode = .off
        }
        session.commitConfiguration()

        // Highest resolution that runs at 60 fps (8-bit), else the best ≥30 fps.
        func score(_ f: AVCaptureDevice.Format) -> Double {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            guard sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return -1 }
            guard d.width <= 4096 else { return -1 }
            let fps = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let px = Double(d.width) * Double(d.height)
            if fps >= 59 { return 1e9 + px }
            if fps >= 29 { return px }
            return -1
        }
        guard let fmt = device.formats.max(by: { score($0) < score($1) }), score(fmt) > 0 else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = fmt
            let fps = min(60, fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
            let dur = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
            device.activeVideoMinFrameDuration = dur
            device.activeVideoMaxFrameDuration = dur
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            // short exposures keep display frames from smearing together
            let maxExp = CMTime(value: 1, timescale: 250)
            if CMTimeCompare(maxExp, fmt.minExposureDuration) > 0 && CMTimeCompare(maxExp, fmt.maxExposureDuration) < 0 {
                device.activeMaxExposureDuration = maxExp
            }
            device.setExposureTargetBias(-0.7)
            if fmt.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = false
            }
            device.unlockForConfiguration()
        } catch {}
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let frame = BGRAFrame(base: base.assumingMemoryBound(to: UInt8.self),
                              width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                              bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
        let (packets, stats) = frameDecoder.decode(frame)
        let now = CACurrentMediaTime()
        var useful = 0
        for p in packets where transfer.ingest(p) { useful += 1 }
        if useful > 0 {
            usefulTimes.append((now, useful))
            lastUseful = now
        }
        if stats.found {
            lastLock = now
            let ok = stats.slots > 0 ? Double(stats.decoded) / Double(stats.slots) : 0
            let load = stats.decoded > 0 ? Double(stats.corrections) / Double(stats.decoded) / Double(max(1, stats.parity / 2)) : 1
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
        let isActive = now - lastUseful < 1.5 && transfer.session != nil
        let isLocked = now - lastLock < 0.3
        let h = !isLocked ? 0 : (okEMA > 0.97 && loadEMA < 0.25 ? 1 : (okEMA < 0.6 ? -1 : 0))
        let exp = transfer.expectedSize ?? 0
        DispatchQueue.main.async {
            if self.received != nil { return }
            self.progress = prog
            self.rate = r
            self.active = isActive
            self.locked = isLocked
            self.hint = h
            self.expected = exp
        }
    }
}
