import AVFoundation
import AppKit
import ScreenCaptureKit

struct RecorderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Microphone choice

enum Mic {
    private static let builtIn: Int32 = 0x626c_746e      // 'bltn'
    private static let bluetooth: Int32 = 0x626c_7565    // 'blue'
    private static let bluetoothLE: Int32 = 0x626c_6561  // 'blea'

    /// The microphone to record from.
    ///
    /// Opening the microphone of Bluetooth headphones switches them into the low quality
    /// "call" profile, so music turns muddy. When the system default input is Bluetooth
    /// we use the Mac's own microphone instead. A wired or USB microphone is respected.
    static func preferred() -> AVCaptureDevice? {
        let fallback = AVCaptureDevice.default(for: .audio)
        guard let current = fallback else { return nil }
        guard current.transportType == bluetooth || current.transportType == bluetoothLE else { return current }
        let all = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
        ).devices
        return all.first { $0.transportType == builtIn } ?? current
    }
}

// MARK: - Camera (+ microphone) to .mov

final class CameraRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "demosufler.camera")
    private var configured = false
    private var audioInput: AVCaptureDeviceInput?
    private var onFinish: (() -> Void)?
    private var recordingRequested = false
    private let lock = NSLock()
    private var startedAtValue: CFTimeInterval = 0

    /// Called when a recording breaks on its own (for example the disk is full).
    var onFailure: ((Error) -> Void)?

    /// The preview layer. It is created on the camera queue, together with the session, and is
    /// never destroyed. Creating or destroying it takes a lock inside the session; if the main
    /// thread did that while the camera was being switched off (which waits for the main
    /// thread), the two would block each other forever. That was the freeze of version 1.0.
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    /// Host time (CACurrentMediaTime) at which the current file started. 0 until it starts.
    var startedAt: CFTimeInterval {
        lock.lock(); defer { lock.unlock() }
        return startedAtValue
    }

    private func configure() throws {
        if configured { return }
        // Prefer the Mac's own camera so a nearby iPhone is not picked up by accident.
        let builtIn = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
        ).devices.first
        guard let cam = builtIn ?? AVCaptureDevice.default(for: .video) else {
            throw RecorderError(tr("No camera found", "Камера не найдена"))
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        let videoIn = try AVCaptureDeviceInput(device: cam)
        guard session.canAddInput(videoIn) else { throw RecorderError(tr("The camera is busy", "Камера занята")) }
        session.addInput(videoIn)
        guard session.canAddOutput(output) else {
            throw RecorderError(tr("Could not set up recording", "Не удалось настроить запись"))
        }
        session.addOutput(output)

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        // The preview is mirrored like a mirror; the file gets the normal picture.
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        previewLayer = layer
        configured = true
    }

    /// Turns the camera on (preview and recording). The completion runs on the main thread.
    func start(completion: @escaping (Error?) -> Void) {
        queue.async {
            var failure: Error?
            do {
                try self.configure()
                if !self.session.isRunning { self.session.startRunning() }
            } catch {
                failure = error
            }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Attaches or detaches the microphone. It is attached only around a recording, so the
    /// orange microphone indicator is off and headphones stay in high quality the rest of the time.
    func setMic(_ enabled: Bool) {
        queue.async {
            guard self.configured, !self.recordingRequested || enabled else { return }
            if enabled, self.audioInput == nil {
                guard let mic = Mic.preferred(), let input = try? AVCaptureDeviceInput(device: mic) else { return }
                self.session.beginConfiguration()
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.audioInput = input
                }
                self.session.commitConfiguration()
            } else if !enabled, let input = self.audioInput {
                self.session.beginConfiguration()
                self.session.removeInput(input)
                self.session.commitConfiguration()
                self.audioInput = nil
            }
        }
    }

    func startRecording(to url: URL) {
        queue.async {
            self.lock.lock(); self.startedAtValue = 0; self.lock.unlock()
            self.recordingRequested = true
            self.output.startRecording(to: url, recordingDelegate: self)
        }
    }

    /// The completion runs once the file is fully written.
    func stopRecording(completion: @escaping () -> Void) {
        queue.async {
            guard self.recordingRequested else {
                completion()
                return
            }
            self.onFinish = completion
            self.output.stopRecording()
            // Never leave the interface stuck on "Saving" if the delegate stays silent.
            self.queue.asyncAfter(deadline: .now() + 6) {
                let done = self.onFinish
                self.onFinish = nil
                done?()
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        lock.lock(); startedAtValue = CACurrentMediaTime(); lock.unlock()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        // AVFoundation sometimes reports an error although the file was finished correctly.
        let finishedOK = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        queue.async {
            self.recordingRequested = false
            let done = self.onFinish
            self.onFinish = nil
            if let done {
                done()
            } else if let error, !finishedOK {
                self.onFailure?(error)
            }
        }
    }
}

// MARK: - Screen (+ microphone) to .mov

struct ScreenOptions {
    var microphone = true
    var fps: Int32 = 30
    var showsCursor = true
    /// Record only these windows of our own app (used by the scripted demo). nil = the whole display.
    var onlyWindows: [CGWindowID]?
}

final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private var recording: SCRecordingOutput?
    private let lock = NSLock()
    private var finished = false
    private var startedAtValue: CFTimeInterval = 0
    private(set) var lastError: Error?
    /// Called when the recording is stopped from outside (menu bar button or the system).
    var onStopped: (() -> Void)?

    private func setFinished(_ value: Bool) {
        lock.lock(); finished = value; lock.unlock()
    }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    /// Host time (CACurrentMediaTime) at which the file started.
    var startedAt: CFTimeInterval {
        lock.lock(); defer { lock.unlock() }
        return startedAtValue
    }

    func start(to url: URL, options: ScreenOptions = ScreenOptions()) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw RecorderError(tr("No display found", "Экран не найден"))
        }

        let filter: SCContentFilter
        if let ids = options.onlyWindows {
            let windows = content.windows.filter { ids.contains($0.windowID) }
            guard !windows.isEmpty else { throw RecorderError("Demo windows not found") }
            for w in windows { print("capture window \(w.windowID) \(w.frame) layer \(w.windowLayer) onScreen \(w.isOnScreen)") }
            filter = SCContentFilter(display: display, including: windows)
        } else {
            // The prompter is cut out of the recording: our whole app is excluded.
            let pid = ProcessInfo.processInfo.processIdentifier
            let me = content.applications.filter { $0.processID == pid }
            filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: options.fps)
        config.showsCursor = options.showsCursor
        config.capturesAudio = false
        config.captureMicrophone = options.microphone
        if options.microphone, let mic = Mic.preferred() {
            config.microphoneCaptureDeviceID = mic.uniqueID
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let outConfig = SCRecordingOutputConfiguration()
        outConfig.outputURL = url
        outConfig.outputFileType = .mov
        // H.264 plays everywhere but stops at 4096 px wide.
        outConfig.videoCodecType = config.width > 4096 ? .hevc : .h264
        let out = SCRecordingOutput(configuration: outConfig, delegate: self)
        try stream.addRecordingOutput(out)

        setFinished(false)
        lastError = nil
        resetStarted()
        try await stream.startCapture()
        markStarted(onlyIfUnset: true)
        self.stream = stream
        self.recording = out
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        // Wait for the file to be finalised (5 seconds at most).
        for _ in 0..<50 where !isFinished {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        self.stream = nil
        self.recording = nil
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        markStarted(onlyIfUnset: false)
    }

    private func resetStarted() {
        lock.lock(); startedAtValue = 0; lock.unlock()
    }

    private func markStarted(onlyIfUnset: Bool) {
        lock.lock()
        if !onlyIfUnset || startedAtValue == 0 { startedAtValue = CACurrentMediaTime() }
        lock.unlock()
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        setFinished(true)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lastError = error
        setFinished(true)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lastError = error
        setFinished(true)
        onStopped?()
    }
}
