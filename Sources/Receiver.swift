import AVFoundation
import Combine
import UIKit
import MainstreamCore

struct Received: Identifiable {
    let id = UUID()
    let payload: Payload
}

/// Receives over the camera (one or two cameras), and owns it for focus control and photos.
final class Receiver: NSObject, ObservableObject {
    @Published var progress: Double = 0
    @Published var active = false
    @Published var locked = false
    @Published var rate: Double = 0
    @Published var hint = 0
    @Published var received: Received?
    @Published private(set) var multiCam = false
    @Published private(set) var dualActive = false
    /// Focus slider value: 0 (closest the main camera goes) … 1 (far); below 0 is macro, on the
    /// ultra-wide camera, when the phone has one that focuses closer.
    @Published var lensPosition: Float = 0.5
    @Published private(set) var manualFocus = false
    @Published private(set) var macroAvailable = false
    @Published private(set) var cameraDenied = false
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var maxZoom: CGFloat = 1
    static let macroRange: Float = 0.6        // slider span below 0
    static let macroLensAtZero: Float = 0.45  // ultra-wide lens position matching the main camera's closest

    static var multiCamSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    /// Preview layers belong to one capture session for life: every rebuilt session gets new
    /// ones. Moving a layer between sessions races iOS's background reconfiguration and aborts
    /// the app (seen on device when switching to two cameras).
    @Published private(set) var preview = Receiver.makeLayer(nil)
    @Published private(set) var pipPreview: AVCaptureVideoPreviewLayer?
    private var session: AVCaptureSession?
    private var devices: [AVCaptureDevice] = []
    private var pipes: [CameraPipe] = []
    private var photoOutput: AVCapturePhotoOutput?
    private var photoDelegates: [PhotoDelegate] = []
    private let sessionQueue = DispatchQueue(label: "mainstream.session")
    // sessionQueue only
    private var running = false
    private var wantMulti = false
    private var pressureWatch: [NSKeyValueObservation] = []
    private var lastRestart: TimeInterval = 0
    private var retired: [AVCaptureSession] = []
    private var macroDevice: AVCaptureDevice?   // single-camera mode: the ultra-wide, if it focuses closer
    private var mainDevice: AVCaptureDevice?
    private var inMacro = false
    private var zoomFactor: CGFloat = 1
    /// main thread: the camera the focus slider follows, and whether it is the macro camera
    private var focusDevice: AVCaptureDevice?
    private var focusIsMacro = false

    // shared decode state (ingestQueue only)
    fileprivate let ingestQueue = DispatchQueue(label: "mainstream.ingest", qos: .userInteractive)
    private let transfer = TransferDecoder()
    private var usefulTimes: [(TimeInterval, Int)] = []
    private var lastUseful: TimeInterval = 0
    private var lastLock: TimeInterval = 0
    private var lastPublish: TimeInterval = 0
    private var okEMA = 0.0, loadEMA = 0.0

    override init() {
        super.init()
        let nc = NotificationCenter.default
        // camera failures (often a multi-camera pair overheating) fall back instead of going dark
        nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: nil) { [weak self] n in self?.sessionFailed(n, interrupted: false) }
        nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: nil, queue: nil) { [weak self] n in self?.sessionFailed(n, interrupted: true) }
    }

    // MARK: lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { if ok { self.start() } else { self.cameraDenied = true } }
            }
            return
        case .denied, .restricted:
            cameraDenied = true
            return
        default:
            cameraDenied = false
        }
        sessionQueue.async { [self] in
            running = true
            if session == nil { build() }
            if let s = session, !s.isRunning { s.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            running = false
            session?.stopRunning()
        }
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
            wantMulti = on
            session?.stopRunning()
            build()
            if running { session?.startRunning() }
        }
    }

    /// sessionQueue: a multi-camera session failed or the phone is too hot for it, so carry on
    /// with one camera (and turn the toggle off).
    private func fallBackToSingleCamera() {
        guard wantMulti else { return }
        wantMulti = false
        session?.stopRunning()
        build()
        if running { session?.startRunning() }
        DispatchQueue.main.async { self.multiCam = false }
    }

    private func sessionFailed(_ n: Notification, interrupted: Bool) {
        guard let s = n.object as? AVCaptureSession else { return }
        if interrupted {
            let reason = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).flatMap(AVCaptureSession.InterruptionReason.init)
            guard reason == .videoDeviceNotAvailableDueToSystemPressure else { return }
        }
        sessionQueue.async { [self] in
            guard s === session else { return }
            if s is AVCaptureMultiCamSession {
                fallBackToSingleCamera()
            } else if !interrupted && running && CACurrentMediaTime() - lastRestart > 2 {
                lastRestart = CACurrentMediaTime()
                s.startRunning()
            }
        }
    }

    // MARK: camera graph

    private static func makeLayer(_ session: AVCaptureSession?, connected: Bool = true) -> AVCaptureVideoPreviewLayer {
        let l: AVCaptureVideoPreviewLayer
        if let session { l = connected ? AVCaptureVideoPreviewLayer(session: session) : AVCaptureVideoPreviewLayer(sessionWithNoConnection: session) } else { l = AVCaptureVideoPreviewLayer() }
        l.videoGravity = .resizeAspectFill
        return l
    }

    /// sessionQueue: a replaced session is only stopped, never reconfigured, and kept alive a
    /// few seconds so iOS can finish with it before it is released.
    private func retire(_ s: AVCaptureSession) {
        s.stopRunning()
        retired.append(s)
        sessionQueue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.retired.removeAll { $0 === s } }
    }

    /// sessionQueue only.
    private func build() {
        pressureWatch.forEach { $0.invalidate() }
        pressureWatch = []
        if let old = session { retire(old) }
        session = nil
        pipes = []
        setDevices([])
        photoOutput = nil
        if wantMulti && Receiver.multiCamSupported, buildMulti() {
            DispatchQueue.main.async { self.dualActive = true }
        } else {
            buildSingle()
            DispatchQueue.main.async { self.dualActive = false }
        }
        // shed frame rate before the system shuts a hot camera down
        pressureWatch = devices.map { d in
            d.observe(\.systemPressureState, options: [.new]) { [weak self] dev, _ in
                let level = dev.systemPressureState.level
                self?.sessionQueue.async { self?.pressureChanged(dev, level) }
            }
        }
    }

    private func setDevices(_ d: [AVCaptureDevice]) {
        devices = d
        let first = d.first, macro = inMacro
        let top = d.map { min(8, $0.maxAvailableVideoZoomFactor / (macro && $0 == macroDevice ? 2 : 1)) }.min() ?? 1
        zoomFactor = min(zoomFactor, max(1, top))
        let z = zoomFactor
        DispatchQueue.main.async {
            self.focusDevice = first
            self.focusIsMacro = macro
            self.maxZoom = max(1, top)
            self.zoom = z
        }
    }

    /// The ultra-wide camera, if its lens can be driven and it focuses closer than `main`.
    private static func macroCandidate(closerThan main: AVCaptureDevice) -> AVCaptureDevice? {
        guard let uw = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back),
              uw.isLockingFocusWithCustomLensPositionSupported, uw.minimumFocusDistance > 0,
              main.minimumFocusDistance <= 0 || uw.minimumFocusDistance < main.minimumFocusDistance else { return nil }
        return uw
    }

    private func buildSingle() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let s = AVCaptureSession()
        s.automaticallyConfiguresApplicationAudioSession = false
        s.beginConfiguration()
        s.sessionPreset = .inputPriority
        if s.canAddInput(input) { s.addInput(input) }
        let pipe = CameraPipe(owner: self, index: 0, workers: 3)
        let out = pipe.makeOutput()
        if s.canAddOutput(out) { s.addOutput(out) }
        if let c = out.connection(with: .video), c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
        let photo = AVCapturePhotoOutput()
        if s.canAddOutput(photo) { s.addOutput(photo); photoOutput = photo }
        s.commitConfiguration()
        _ = configure(device, formats: device.formats, cost: nil)
        session = s
        mainDevice = device
        macroDevice = Receiver.macroCandidate(closerThan: device)
        inMacro = false
        setDevices([device])
        applyZoom()
        pipes = [pipe]
        let layer = Receiver.makeLayer(s)
        let macro = macroDevice != nil
        DispatchQueue.main.async {
            self.preview = layer
            self.pipPreview = nil
            self.macroAvailable = macro
        }
    }

    /// sessionQueue, single-camera session: move between the main and the macro camera.
    private func switchCamera(toMacro macro: Bool) {
        guard macro != inMacro, let s = session, !(s is AVCaptureMultiCamSession),
              let dev = macro ? macroDevice : mainDevice, let input = try? AVCaptureDeviceInput(device: dev) else { return }
        s.beginConfiguration()
        for i in s.inputs { s.removeInput(i) }
        guard s.canAddInput(input) else {
            if let back = macro ? mainDevice : macroDevice, let bi = try? AVCaptureDeviceInput(device: back), s.canAddInput(bi) { s.addInput(bi) }
            s.commitConfiguration()
            return
        }
        s.addInput(input)
        for o in s.outputs { if let c = o.connection(with: .video), c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off } }
        s.commitConfiguration()
        _ = configure(dev, formats: dev.formats, cost: nil)
        inMacro = macro
        setDevices([dev])
        applyZoom()
        pressureWatch.forEach { $0.invalidate() }
        pressureWatch = [dev.observe(\.systemPressureState, options: [.new]) { [weak self] d, _ in
            let level = d.systemPressureState.level
            self?.sessionQueue.async { self?.pressureChanged(d, level) }
        }]
        DispatchQueue.main.async {
            if let c = self.preview.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }
    }

    /// sessionQueue: zoom every active camera; the macro camera is cropped 2× more so its much
    /// wider view matches the main camera's.
    private func applyZoom() {
        for d in devices where (try? d.lockForConfiguration()) != nil {
            let z = zoomFactor * (inMacro && d == macroDevice ? 2 : 1)
            d.videoZoomFactor = max(d.minAvailableVideoZoomFactor, min(d.maxAvailableVideoZoomFactor, z))
            d.unlockForConfiguration()
        }
    }

    /// Wide + ultra-wide (or telephoto) running together; both feed one transfer. Returns false,
    /// leaving nothing attached, if the pair can't be set up within the hardware budget.
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
        var photo: AVCapturePhotoOutput?
        var ports: [AVCaptureInput.Port] = []
        for (i, dev) in [wide, second].enumerated() {
            guard let input = try? AVCaptureDeviceInput(device: dev), s.canAddInput(input) else { ok = false; break }
            s.addInputWithNoConnections(input)
            guard let port = input.ports(for: .video, sourceDeviceType: dev.deviceType, sourceDevicePosition: .back).first else { ok = false; break }
            let pipe = CameraPipe(owner: self, index: i, workers: 2)
            let out = pipe.makeOutput()
            guard s.canAddOutput(out) else { ok = false; break }
            s.addOutputWithNoConnections(out)
            let c = AVCaptureConnection(inputPorts: [port], output: out)
            guard s.canAddConnection(c) else { ok = false; break }
            s.addConnection(c)
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
            newPipes.append(pipe)
            ports.append(port)
            if i == 0 {
                let p = AVCapturePhotoOutput()
                if s.canAddOutput(p) {
                    s.addOutputWithNoConnections(p)
                    let ph = AVCaptureConnection(inputPorts: [port], output: p)
                    if s.canAddConnection(ph) { s.addConnection(ph); photo = p }
                }
            }
        }
        // Two streams at up to 1440p each: 4K pairs exhaust the bandwidth and memory budget on
        // most phones, and the pair is there for a second look, not for resolution.
        if ok {
            for dev in [wide, second] {
                let formats = dev.formats.filter { $0.isMultiCamSupported && CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= 1920 }
                if !configure(dev, formats: formats, cost: s) { ok = false; break }
            }
        }
        s.commitConfiguration()
        guard ok, ports.count == 2, s.hardwareCost <= 1, s.systemPressureCost <= 1 else {
            // never started and no preview attached: just let it go
            retire(s)
            return false
        }
        // previews only once the pair is known to work, each on its own new layer
        let layers = [Receiver.makeLayer(s, connected: false), Receiver.makeLayer(s, connected: false)]
        s.beginConfiguration()
        for (port, layer) in zip(ports, layers) {
            let pc = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
            if s.canAddConnection(pc) { s.addConnection(pc) }
        }
        s.commitConfiguration()
        DispatchQueue.main.async {
            self.preview = layers[0]
            self.pipPreview = layers[1]
        }
        session = s
        mainDevice = wide
        macroDevice = nil
        inMacro = false
        setDevices([wide, second])
        applyZoom()
        pipes = newPipes
        photoOutput = photo
        let macro = second.deviceType == .builtInUltraWideCamera && Receiver.macroCandidate(closerThan: wide) != nil
        DispatchQueue.main.async { self.macroAvailable = macro }
        return true
    }

    /// Sets a frame duration the active format actually supports (an unsupported one throws).
    private func setFrameRate(_ device: AVCaptureDevice, _ fps: Double) {
        guard let r = device.activeFormat.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return }
        var dur = CMTime(value: 1000, timescale: CMTimeScale((min(fps, r.maxFrameRate) * 1000).rounded()))
        if CMTimeCompare(dur, r.minFrameDuration) < 0 { dur = r.minFrameDuration }
        if CMTimeCompare(dur, r.maxFrameDuration) > 0 { dur = r.maxFrameDuration }
        device.activeVideoMinFrameDuration = dur
        device.activeVideoMaxFrameDuration = dur
    }

    /// 60 fps at the highest resolution available (within the multi-cam budget, where 30 fps is
    /// the fallback), short exposures, near-range autofocus. False if nothing fits the budget.
    private func configure(_ device: AVCaptureDevice, formats: [AVCaptureDevice.Format], cost: AVCaptureMultiCamSession?) -> Bool {
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
        guard (try? device.lockForConfiguration()) != nil else { return false }
        defer { device.unlockForConfiguration() }
        var fits = cost == nil
        search: for fmt in candidates {
            device.activeFormat = fmt
            for rate in cost == nil ? [60.0] : [60, 30] {
                setFrameRate(device, rate)
                if let s = cost, s.hardwareCost > 1 { continue }
                fits = true
                break search
            }
        }
        guard fits else { return false }
        let fmt = device.activeFormat
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        let maxExp = CMTime(value: 1, timescale: 250)
        if CMTimeCompare(maxExp, fmt.minExposureDuration) > 0 && CMTimeCompare(maxExp, fmt.maxExposureDuration) < 0 {
            device.activeMaxExposureDuration = maxExp
        }
        device.setExposureTargetBias(max(device.minExposureTargetBias, min(device.maxExposureTargetBias, -0.7)))
        if fmt.isVideoHDRSupported {
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = false
        }
        return true
    }

    /// sessionQueue: halve the frame rate under thermal or power pressure, restore it when it
    /// eases, and drop to one camera before the system shuts the pair down.
    private func pressureChanged(_ device: AVCaptureDevice, _ level: AVCaptureDevice.SystemPressureState.Level) {
        guard devices.contains(device) else { return }
        if level == .shutdown || (level == .critical && devices.count > 1) {
            fallBackToSingleCamera()
            return
        }
        guard (try? device.lockForConfiguration()) != nil else { return }
        setFrameRate(device, level == .serious || level == .critical ? 30 : 60)
        device.unlockForConfiguration()
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
                if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = dp }
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                d.unlockForConfiguration()
            }
        }
    }

    /// Manual focus from the slider: 0 (main camera's closest) … 1 (far). Below 0 continues on
    /// the ultra-wide camera, which focuses much closer.
    func setLens(_ v: Float) {
        manualFocus = true
        lensPosition = v
        sessionQueue.async { [self] in
            if macroDevice != nil { switchCamera(toMacro: v < 0) }
            // slider below 0 → ultra-wide lens from its main-camera-equivalent position down to its closest
            let macroLens = max(0, Receiver.macroLensAtZero * (v + Receiver.macroRange) / Receiver.macroRange)
            for d in devices where d.isLockingFocusWithCustomLensPositionSupported && (try? d.lockForConfiguration()) != nil {
                let ultra = d.deviceType == .builtInUltraWideCamera
                d.setFocusModeLocked(lensPosition: v < 0 ? (ultra ? macroLens : 0) : v)
                d.unlockForConfiguration()
            }
        }
    }

    /// Zoom, 1× = the main camera's normal view (main thread).
    func setZoom(_ z: CGFloat) {
        let c = max(1, min(maxZoom, z))
        zoom = c
        sessionQueue.async { [self] in
            zoomFactor = c
            applyZoom()
        }
    }

    func continuousFocus() {
        manualFocus = false
        sessionQueue.async { [self] in
            switchCamera(toMacro: false)
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
            // the camera is off while sending: run it just long enough for the shot
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
                if !wasRunning { self?.sessionQueue.async { if self?.running == false { s.stopRunning() } } }
            }
            DispatchQueue.main.async { self.photoDelegates.append(del) }
            out.capturePhoto(with: settings, delegate: del)
        }
    }

    // MARK: shared ingest (ingestQueue)

    fileprivate func absorb(_ packets: [Packet], found: Bool, ok: Double, load: Double) {
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
        let isActive = now - lastUseful < 1.5 && transfer.session != nil
        let isLocked = now - lastLock < 0.3
        let h = !isLocked ? 0 : (okEMA > 0.97 && loadEMA < 0.25 ? 1 : (okEMA < 0.6 ? -1 : 0))
        DispatchQueue.main.async {
            if self.received != nil { return }
            self.progress = prog
            self.rate = r
            self.active = isActive
            self.locked = isLocked
            self.hint = h
            if !self.manualFocus, let d = self.focusDevice {
                self.lensPosition = self.focusIsMacro
                    ? min(0, d.lensPosition / Receiver.macroLensAtZero * Receiver.macroRange - Receiver.macroRange)
                    : d.lensPosition
            }
        }
    }
}

/// One camera's decode path.
/// One camera's decode path. Frames are decoded by a small pool so a slow frame doesn't make
/// the camera drop the next ones; when every decoder is busy the new frame is skipped.
private final class CameraPipe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var owner: Receiver?
    let queue: DispatchQueue
    private let decodeQueue: DispatchQueue
    private let lock = NSLock()
    private var idle: [FrameDecoder]

    init(owner: Receiver, index: Int, workers: Int) {
        self.owner = owner
        queue = DispatchQueue(label: "mainstream.video.\(index)", qos: .userInteractive)
        decodeQueue = DispatchQueue(label: "mainstream.decode.\(index)", qos: .userInteractive, attributes: .concurrent)
        idle = (0..<workers).map { _ in FrameDecoder() }
    }

    func makeOutput() -> AVCaptureVideoDataOutput {
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        return out
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard owner != nil else { return }
        lock.lock()
        let decoder = idle.popLast()
        lock.unlock()
        guard let decoder else { return }
        decodeQueue.async { [weak self] in
            defer { self?.lock.lock(); self?.idle.append(decoder); self?.lock.unlock() }
            guard let owner = self?.owner, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
            let f = BGRAFrame(base: base.assumingMemoryBound(to: UInt8.self), width: CVPixelBufferGetWidth(pb),
                              height: CVPixelBufferGetHeight(pb), bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
            let (packets, stats) = decoder.decode(f)
            let ok = stats.slots > 0 ? Double(stats.decoded) / Double(stats.slots) : 0
            let load = stats.decoded > 0 ? Double(stats.corrections) / Double(stats.decoded) / Double(max(1, stats.parity / 2)) : 1
            owner.ingestQueue.async { owner.absorb(packets, found: stats.found, ok: ok, load: load) }
        }
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let done: (Data?, PhotoDelegate) -> Void
    init(_ done: @escaping (Data?, PhotoDelegate) -> Void) { self.done = done }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        done(photo.fileDataRepresentation(), self)
    }
}
