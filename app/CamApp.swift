// The camera window. Opens a live preview; Space adds a photo to the tray, Enter
// sends the tray (or takes one photo and sends it when the tray is empty), Delete
// drops the last photo, Esc discards everything. Every run ends by writing
// "<out>.result" (see RunResult) and quitting. Launched by bin/herdr-cam via
// `open -W`, so it is its own app for camera permission purposes.

import AVFoundation
import AppKit

@main
enum HerdrCamMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let opts: Options
        do {
            opts = try parseOptions(args)
        } catch {
            // LaunchServices drops our stderr, so report through the result file.
            if let base = outArgument(args) { writeResult(.error("HerdrCam: \(error)"), base: base) }
            FileHandle.standardError.write(Data("herdr-cam: \(error)\n".utf8))
            exit(2)
        }

        if !opts.fakeImages.isEmpty {
            exit(runFake(opts))
        }

        let app = NSApplication.shared
        let delegate = AppDelegate(opts: opts)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Headless path for test builds: the same pipeline and result file, no camera.
    static func runFake(_ opts: Options) -> Int32 {
        var tray = Tray(base: opts.out, limit: opts.maxShots)
        do {
            for path in opts.fakeImages {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let out = tray.nextPath()
                try writeAtomically(processImage(data, maxEdge: opts.maxEdge, quality: opts.quality), to: out)
                tray.add(out)
            }
            writeResult(.ok(tray.shots), base: opts.out)
            return 0
        } catch {
            writeResult(.error("fake image failed: \(error)"), base: opts.out)
            return 1
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let opts: Options
    var window: CamWindow!
    let camera = Camera()
    var tray: Tray
    var mirrored = UserDefaults.standard.bool(forKey: "mirrored")
    var countdownTimer: Timer?
    var countdown: Int?
    var busy = false
    var finished = false
    var idleTimer: Timer?

    init(opts: Options) {
        self.opts = opts
        self.tray = Tray(base: opts.out, limit: opts.maxShots)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        buildWindow()
        bringForward()
        resetIdle()
        camera.onLost = { [weak self] in self?.cameraLost() }

        if let path = opts.focusCheck {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let state = "active=\(NSApp.isActive) key=\(self.window.isKeyWindow)\n"
                try? writeAtomically(Data(state.utf8), to: path)
                self.finish(.cancel)
            }
            return
        }

        Camera.authorize { granted in
            guard granted else {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
                self.finish(.error(
                    "Camera access is off for HerdrCam. Turn it on in System Settings > Privacy & Security > Camera, then press the key again."
                ))
                return
            }
            self.startCamera(preferred: UserDefaults.standard.string(forKey: "camera"))
        }
    }

    /// The window must take the keyboard, or Space goes to the terminal behind it.
    /// macOS 14+ will not let an app launched from a background process (herdr's
    /// server) activate itself with NSApp.activate(); a non-activating panel can still
    /// become key, the way Spotlight-style windows do, and the terminal stays the
    /// active app. If the panel is ever refused, fall back to the older call.
    func bringForward() {
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !self.finished, !self.window.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationDidBecomeActive(_ note: Notification) { window?.makeKeyAndOrderFront(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func windowWillClose(_ note: Notification) { finish(.cancel) }

    func applicationWillTerminate(_ note: Notification) {
        if !finished { finish(.cancel, quit: false) }
        camera.stopSync()
    }

    /// Every key press restarts the clock; when it runs out the window closes and the
    /// photos are discarded, so the camera is never left on unattended.
    func resetIdle() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(opts.idleSeconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.cancel) }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    /// The single exit: discard photos unless sending, write the result, quit.
    func finish(_ result: RunResult, quit: Bool = true) {
        guard !finished else { return }
        finished = true
        countdownTimer?.invalidate()
        idleTimer?.invalidate()
        if case .ok = result {} else {
            for path in tray.shots { try? FileManager.default.removeItem(atPath: path) }
        }
        writeResult(result, base: opts.out)
        camera.stopSync()
        if quit { NSApp.terminate(nil) }
    }

    // MARK: window

    func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        window = CamWindow(
            contentRect: frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.title = "herdr-cam"
        window.level = .floating
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false  // stay up if you click the terminal to read
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.onKey = { [weak self] cmd in self?.handle(cmd) }
        window.contentAspectRatio = NSSize(width: 16, height: 9)

        let view = PreviewView(frame: frame)
        view.previewLayer.session = camera.session
        window.contentView = view
        window.center()
        refreshHUD()
    }

    var preview: PreviewView { window.contentView as! PreviewView }

    func refreshHUD(note: String? = nil) {
        preview.hud.stringValue = note ?? hudText(
            camera: camera.current?.localizedName ?? "starting camera…", mirrored: mirrored,
            countdown: countdown, shots: tray.shots.count)
    }

    /// Mirrors the preview only. The saved photo is never mirrored, so text in it
    /// stays readable.
    func applyMirror() {
        guard let conn = preview.previewLayer.connection, conn.isVideoMirroringSupported else { return }
        conn.automaticallyAdjustsVideoMirroring = false
        conn.isVideoMirrored = mirrored
    }

    /// Match the window to the camera's frame shape so the preview shows the photo's
    /// framing with no letterboxing, kept within the screen.
    func fitWindowToCamera() {
        guard let device = camera.current else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dims.width > 0, dims.height > 0 else { return }
        let aspect = CGFloat(dims.width) / CGFloat(dims.height)
        window.contentAspectRatio = NSSize(width: Int(dims.width), height: Int(dims.height))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var width = min(window.contentLayoutRect.width, visible.width * 0.9)
        var height = width / aspect
        if height > visible.height * 0.85 {
            height = visible.height * 0.85
            width = height * aspect
        }
        window.setFrame(window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height)), display: true)
        window.center()
    }

    // MARK: camera

    func startCamera(preferred: String?) {
        camera.start(preferredID: preferred) { ok in
            guard ok else {
                self.finish(.error("No camera could be opened. Check that no other app is using it."))
                return
            }
            self.applyMirror()
            self.fitWindowToCamera()
            self.refreshHUD()
            if self.opts.autoCapture != nil { self.runAuto(shotsLeft: self.opts.autoShots) }
        }
    }

    /// The camera in use went away (unplugged, iPhone walked off). Fall back to
    /// another camera, or end with an error rather than a crash.
    func cameraLost() {
        guard !finished else { return }
        busy = false
        refreshHUD(note: "Camera disconnected, switching…")
        startCamera(preferred: nil)
    }

    /// Test builds only: count down, capture, repeat, then send.
    func runAuto(shotsLeft: Int) {
        guard let n = opts.autoCapture else { return }
        startCountdown(shotsLeft == opts.autoShots ? n : 1) { [weak self] in
            guard let self else { return }
            self.capture { [weak self] in
                guard let self else { return }
                if shotsLeft > 1 { self.runAuto(shotsLeft: shotsLeft - 1) } else { self.finish(.ok(self.tray.shots)) }
            }
        }
    }

    func startCountdown(_ seconds: Int, then action: @escaping () -> Void) {
        guard countdown == nil, !busy else { return }
        countdown = seconds
        refreshHUD()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let n = self.countdown else { return t.invalidate() }
                if n <= 1 {
                    t.invalidate()
                    self.countdown = nil
                    self.refreshHUD()
                    action()
                } else {
                    self.countdown = n - 1
                    self.refreshHUD()
                }
            }
        }
        // .common keeps the countdown running while the window is being resized.
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    func handle(_ cmd: CamCommand) {
        guard !finished else { return }
        resetIdle()
        switch cmd {
        case .cancel:
            finish(.cancel)
        case .capture:
            guard countdown == nil else { return }
            capture()
        case .send:
            guard countdown == nil, !busy else { return }
            if tray.shots.isEmpty {
                capture { [weak self] in self.map { $0.finish(.ok($0.tray.shots)) } }
            } else {
                finish(.ok(tray.shots))
            }
        case .undo:
            guard countdown == nil, !busy, let path = tray.undo() else { return }
            try? FileManager.default.removeItem(atPath: path)
            preview.setThumbnails(tray.shots)
            refreshHUD()
        case .timedCapture:
            startCountdown(opts.timerSeconds) { [weak self] in self?.capture() }
        case .nextCamera:
            guard !busy, countdown == nil else { return }
            let previous = camera.current?.localizedName
            camera.next { ok in
                if ok {
                    UserDefaults.standard.set(self.camera.current?.uniqueID, forKey: "camera")
                    self.applyMirror()
                    self.fitWindowToCamera()
                    self.refreshHUD()
                } else if let previous {
                    self.refreshHUD(note: "That camera could not be opened; staying on \(previous)")
                }
            }
        case .toggleMirror:
            mirrored.toggle()
            UserDefaults.standard.set(mirrored, forKey: "mirrored")
            applyMirror()
            refreshHUD()
        }
    }

    func capture(then: (() -> Void)? = nil) {
        guard !busy, !finished, camera.isReady else { return }
        guard !tray.isFull else {
            refreshHUD(note: "Tray is full (\(tray.limit) photos). Enter sends, Delete removes the last one.")
            return
        }
        busy = true
        preview.flash()
        // If the camera never answers, end with a message instead of hanging.
        let watchdog = Timer(timeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.error("The camera stopped responding.")) }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        camera.capture { data in
            watchdog.invalidate()
            guard !self.finished else { return }
            self.busy = false
            guard let data else {
                self.refreshHUD(note: "Capture failed. Try again, or press C for another camera.")
                return
            }
            let path = self.tray.nextPath()
            do {
                try writeAtomically(
                    processImage(data, maxEdge: self.opts.maxEdge, quality: self.opts.quality), to: path)
            } catch {
                self.finish(.error("Could not save the photo: \(error)"))
                return
            }
            self.tray.add(path)
            self.preview.setThumbnails(self.tray.shots)
            self.refreshHUD()
            then?()
        }
    }
}

// MARK: - Camera

/// Owns the capture session. Session work runs on `queue`; `current`, `isReady`,
/// and every callback are main-thread only.
final class Camera: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "herdr-cam.session")
    private(set) var current: AVCaptureDevice?
    private(set) var isReady = false
    private var input: AVCaptureDeviceInput?
    private var onPhoto: ((Data?) -> Void)?
    var onLost: (() -> Void)?

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(deviceGone(_:)), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        nc.addObserver(self, selector: #selector(sessionFailed(_:)), name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    @objc private func deviceGone(_ note: Notification) {
        guard let device = note.object as? AVCaptureDevice else { return }
        DispatchQueue.main.async {
            guard device.uniqueID == self.current?.uniqueID else { return }
            self.lost()
        }
    }

    @objc private func sessionFailed(_ note: Notification) {
        DispatchQueue.main.async { self.lost() }
    }

    private func lost() {
        isReady = false
        current = nil
        let pending = onPhoto
        onPhoto = nil
        pending?(nil)
        onLost?()
    }

    static func authorize(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    static func devices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .deskViewCamera]
        if #available(macOS 14.0, *) { types += [.external, .continuityCamera] }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        ).devices
    }

    /// Opens the remembered camera, else the system's preferred one, else any camera
    /// that works, trying each in turn.
    func start(preferredID: String?, done: @escaping (Bool) -> Void) {
        let all = Camera.devices()
        var order: [AVCaptureDevice] = []
        if let p = all.first(where: { $0.uniqueID == preferredID }) { order.append(p) }
        if #available(macOS 14.0, *), let sys = AVCaptureDevice.systemPreferredCamera,
            !order.contains(where: { $0.uniqueID == sys.uniqueID }), all.contains(where: { $0.uniqueID == sys.uniqueID })
        {
            order.append(sys)
        }
        order += all.filter { d in !order.contains(where: { $0.uniqueID == d.uniqueID }) }
        tryOpen(order, done: done)
    }

    private func tryOpen(_ candidates: [AVCaptureDevice], done: @escaping (Bool) -> Void) {
        guard let device = candidates.first else { return done(false) }
        switchTo(device) { ok in
            if ok {
                self.queue.async {
                    if !self.session.isRunning { self.session.startRunning() }
                    let running = self.session.isRunning
                    DispatchQueue.main.async {
                        self.isReady = running
                        running ? done(true) : self.tryOpen(Array(candidates.dropFirst()), done: done)
                    }
                }
            } else {
                self.tryOpen(Array(candidates.dropFirst()), done: done)
            }
        }
    }

    func next(done: @escaping (Bool) -> Void) {
        let all = Camera.devices()
        guard all.count > 1 else { return done(false) }
        let idx = all.firstIndex(where: { $0.uniqueID == current?.uniqueID }) ?? -1
        switchTo(all[(idx + 1) % all.count], done: done)
    }

    /// Swaps the session input. The new input is created before the old one is
    /// removed, and the old one is put back if the new one is refused, so a failed
    /// switch never leaves the session without a camera.
    private func switchTo(_ device: AVCaptureDevice, done: @escaping (Bool) -> Void) {
        isReady = false
        queue.async {
            guard let newInput = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async {
                    self.isReady = self.input != nil && self.session.isRunning
                    done(false)
                }
                return
            }
            self.session.beginConfiguration()
            let old = self.input
            if let old { self.session.removeInput(old) }
            var ok = false
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.input = newInput
                ok = true
            } else if let old, self.session.canAddInput(old) {
                self.session.addInput(old)
            }
            self.session.sessionPreset = self.session.canSetSessionPreset(.photo) ? .photo : .high
            if !self.session.outputs.contains(self.output), self.session.canAddOutput(self.output) {
                self.session.addOutput(self.output)
            }
            self.session.commitConfiguration()
            let running = self.session.isRunning
            DispatchQueue.main.async {
                if ok { self.current = device }
                self.isReady = running && self.input != nil
                done(ok)
            }
        }
    }

    func capture(_ done: @escaping (Data?) -> Void) {
        onPhoto = done
        queue.async {
            // capturePhoto throws an exception without a live video connection.
            guard let conn = self.output.connection(with: .video), conn.isActive, conn.isEnabled else {
                DispatchQueue.main.async {
                    let pending = self.onPhoto
                    self.onPhoto = nil
                    pending?(nil)
                }
                return
            }
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    /// Stops the session before returning, so the camera light goes off promptly.
    func stopSync() {
        queue.sync { if self.session.isRunning { self.session.stopRunning() } }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        DispatchQueue.main.async {
            let pending = self.onPhoto
            self.onPhoto = nil
            pending?(data)
        }
    }
}

// MARK: - Views

final class CamWindow: NSPanel {
    var onKey: ((CamCommand) -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let modified = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if let cmd = camCommand(
            characters: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode, modified: modified)
        {
            onKey?(cmd)
        } else {
            super.keyDown(with: event)
        }
    }

    // Esc on a titled window would otherwise beep via cancelOperation.
    override func cancelOperation(_ sender: Any?) { onKey?(.cancel) }
}

final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    let flashLayer = CALayer()
    let hud = NSTextField(labelWithString: "")
    let thumbs = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        previewLayer.videoGravity = .resizeAspect
        previewLayer.frame = bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(previewLayer)

        flashLayer.backgroundColor = NSColor.white.cgColor
        flashLayer.opacity = 0
        flashLayer.frame = bounds
        flashLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(flashLayer)

        hud.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        hud.textColor = .white
        hud.alignment = .center
        hud.lineBreakMode = .byTruncatingMiddle
        hud.drawsBackground = true
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        hud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hud)

        // The tray: small thumbnails of the photos taken so far, top-left.
        thumbs.orientation = .horizontal
        thumbs.spacing = 8
        thumbs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbs)

        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: trailingAnchor),
            hud.bottomAnchor.constraint(equalTo: bottomAnchor),
            hud.heightAnchor.constraint(equalToConstant: 28),
            thumbs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            thumbs.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func setThumbnails(_ paths: [String]) {
        thumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, path) in paths.enumerated() {
            let view = NSImageView()
            view.image = NSImage(contentsOfFile: path)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.borderColor = NSColor.white.cgColor
            view.layer?.borderWidth = 2
            view.layer?.cornerRadius = 4
            view.layer?.masksToBounds = true
            view.toolTip = "Photo \(i + 1)"
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: 88),
                view.heightAnchor.constraint(equalToConstant: 56),
            ])
            thumbs.addArrangedSubview(view)
        }
    }

    func flash() {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.85
        anim.toValue = 0
        anim.duration = 0.3
        flashLayer.add(anim, forKey: "flash")
    }
}
