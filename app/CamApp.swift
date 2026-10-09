// The camera window. Opens a live preview, captures one photo on Space (or after a
// T countdown), writes it to --out through the Core pipeline, and quits. Esc quits
// without writing anything. Launched by bin/herdr-cam via `open -W`, so it is its own
// app for camera permission purposes.

import AVFoundation
import AppKit

@main
enum HerdrCamMain {
    static func main() {
        let opts: Options
        do {
            opts = try parseOptions(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("herdr-cam: \(error)\n".utf8))
            exit(2)
        }

        if let fake = opts.fakeImage {
            exit(runFake(fake, opts: opts))
        }

        let app = NSApplication.shared
        let delegate = AppDelegate(opts: opts)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Headless path for tests: same pipeline, no camera, no window.
    static func runFake(_ path: String, opts: Options) -> Int32 {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            try writeAtomically(processImage(data, maxEdge: opts.maxEdge, quality: opts.quality), to: opts.out)
            return 0
        } catch {
            writeError("fake image failed: \(error)", out: opts.out)
            return 1
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let opts: Options
    var window: CamWindow!
    let camera = Camera()
    var mirrored = UserDefaults.standard.bool(forKey: "mirrored")
    var countdownTimer: Timer?
    var countdown: Int?
    var busy = false

    init(opts: Options) { self.opts = opts }

    func applicationDidFinishLaunching(_ note: Notification) {
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        Camera.authorize { granted in
            guard granted else {
                writeError(
                    "Camera access denied. Allow HerdrCam in System Settings > Privacy & Security > Camera.",
                    out: self.opts.out)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
                NSApp.terminate(nil)
                return
            }
            self.startCamera(preferred: UserDefaults.standard.string(forKey: "camera"))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func windowWillClose(_ note: Notification) { camera.stop() }

    // MARK: window

    func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        window = CamWindow(
            contentRect: frame, styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "herdr-cam"
        window.level = .floating
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.onKey = { [weak self] cmd in self?.handle(cmd) }
        window.contentAspectRatio = NSSize(width: 4, height: 3)

        let view = PreviewView(frame: frame)
        view.previewLayer.session = camera.session
        window.contentView = view
        window.center()
        refreshHUD()
    }

    var preview: PreviewView { window.contentView as! PreviewView }

    func refreshHUD() {
        preview.hud.stringValue = hudText(
            camera: camera.current?.localizedName ?? "no camera", mirrored: mirrored, countdown: countdown)
    }

    /// Match the window to the camera's frame shape so the preview shows exactly
    /// what the photo will contain, with no letterboxing.
    func fitWindowToCamera() {
        guard let device = camera.current else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dims.width > 0, dims.height > 0 else { return }
        let aspect = NSSize(width: Int(dims.width), height: Int(dims.height))
        window.contentAspectRatio = aspect
        let width = window.contentLayoutRect.width
        var frame = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: width, height: width * aspect.height / aspect.width))
        frame.origin = window.frame.origin
        window.setFrame(frame, display: true)
        window.center()
    }

    func applyMirror() {
        guard let conn = preview.previewLayer.connection, conn.isVideoMirroringSupported else { return }
        conn.automaticallyAdjustsVideoMirroring = false
        conn.isVideoMirrored = mirrored
    }

    // MARK: camera

    func startCamera(preferred: String?) {
        camera.start(preferredID: preferred) { ok in
            guard ok else {
                writeError("No camera found.", out: self.opts.out)
                NSApp.terminate(nil)
                return
            }
            self.applyMirror()
            self.fitWindowToCamera()
            self.refreshHUD()
            if let n = self.opts.autoCapture { self.startCountdown(n) }
        }
    }

    func startCountdown(_ seconds: Int) {
        guard countdown == nil, !busy else { return }
        countdown = seconds
        refreshHUD()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self, let n = self.countdown else { return }
            if n <= 1 {
                t.invalidate()
                self.countdown = nil
                self.refreshHUD()
                self.capture()
            } else {
                self.countdown = n - 1
                self.refreshHUD()
            }
        }
    }

    func handle(_ cmd: CamCommand) {
        switch cmd {
        case .cancel:
            countdownTimer?.invalidate()
            NSApp.terminate(nil)
        case .capture:
            guard countdown == nil else { return }
            capture()
        case .timedCapture:
            startCountdown(opts.timerSeconds)
        case .nextCamera:
            guard !busy, countdown == nil else { return }
            camera.next { _ in
                UserDefaults.standard.set(self.camera.current?.uniqueID, forKey: "camera")
                self.applyMirror()
                self.fitWindowToCamera()
                self.refreshHUD()
            }
        case .toggleMirror:
            mirrored.toggle()
            UserDefaults.standard.set(mirrored, forKey: "mirrored")
            applyMirror()
            refreshHUD()
        }
    }

    func capture() {
        guard !busy, camera.current != nil else { return }
        busy = true
        preview.flash()
        camera.capture { data in
            guard let data else {
                writeError("Capture failed.", out: self.opts.out)
                NSApp.terminate(nil)
                return
            }
            do {
                let jpeg = try processImage(data, maxEdge: self.opts.maxEdge, quality: self.opts.quality)
                try writeAtomically(jpeg, to: self.opts.out)
            } catch {
                writeError("Could not save photo: \(error)", out: self.opts.out)
            }
            // Let the flash finish so the capture feels acknowledged.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Camera

final class Camera: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "herdr-cam.session")
    private(set) var current: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private var onPhoto: ((Data?) -> Void)?

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

    func start(preferredID: String?, done: @escaping (Bool) -> Void) {
        let all = Camera.devices()
        guard let device = all.first(where: { $0.uniqueID == preferredID }) ?? all.first else {
            done(false)
            return
        }
        switchTo(device) { ok in
            self.queue.async {
                self.session.startRunning()
                DispatchQueue.main.async { done(ok) }
            }
        }
    }

    func next(done: @escaping (Bool) -> Void) {
        let all = Camera.devices()
        guard all.count > 1 else { return done(false) }
        let idx = all.firstIndex(where: { $0.uniqueID == current?.uniqueID }) ?? -1
        switchTo(all[(idx + 1) % all.count], done: done)
    }

    private func switchTo(_ device: AVCaptureDevice, done: @escaping (Bool) -> Void) {
        queue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            if let old = self.input { self.session.removeInput(old) }
            var ok = false
            if let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                self.session.addInput(input)
                self.input = input
                ok = true
            }
            if !self.session.outputs.contains(self.output), self.session.canAddOutput(self.output) {
                self.session.addOutput(self.output)
            }
            self.session.commitConfiguration()
            DispatchQueue.main.async {
                if ok { self.current = device }
                done(ok)
            }
        }
    }

    func capture(_ done: @escaping (Data?) -> Void) {
        onPhoto = done
        queue.async {
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        DispatchQueue.main.async {
            self.onPhoto?(data)
            self.onPhoto = nil
        }
    }
}

// MARK: - Views

final class CamWindow: NSWindow {
    var onKey: ((CamCommand) -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let cmd = camCommand(characters: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode) {
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

        hud.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        hud.textColor = .white
        hud.alignment = .center
        hud.wantsLayer = true
        hud.drawsBackground = true
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        hud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hud)
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: trailingAnchor),
            hud.bottomAnchor.constraint(equalTo: bottomAnchor),
            hud.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func flash() {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.85
        anim.toValue = 0
        anim.duration = 0.3
        flashLayer.add(anim, forKey: "flash")
    }
}
