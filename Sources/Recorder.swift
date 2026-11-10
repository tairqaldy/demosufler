import AVFoundation
import AppKit
import ScreenCaptureKit

struct RecorderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Камера (+ микрофон) в .mov

final class CameraRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "demosufler.camera")
    private var configured = false
    private var onFinish: (() -> Void)?
    /// Вызывается, если запись оборвалась сама (например, кончилось место на диске).
    var onFailure: ((Error) -> Void)?

    private func configure() throws {
        if configured { return }
        // Сначала встроенная камера макбука, чтобы случайно не подхватить айфон.
        let builtIn = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
        ).devices.first
        guard let cam = builtIn ?? AVCaptureDevice.default(for: .video) else {
            throw RecorderError("Камера не найдена")
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        let videoIn = try AVCaptureDeviceInput(device: cam)
        guard session.canAddInput(videoIn) else { throw RecorderError("Камера занята") }
        session.addInput(videoIn)
        if let mic = AVCaptureDevice.default(for: .audio),
           let audioIn = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audioIn) {
            session.addInput(audioIn)
        }
        guard session.canAddOutput(output) else { throw RecorderError("Не удалось настроить запись") }
        session.addOutput(output)
        configured = true
    }

    /// Включает камеру (для превью и записи). completion приходит на главный поток.
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

    /// true от startRecording до ответа делегата. output.isRecording для этого не годится:
    /// он включается с задержкой, и быстрый «Стоп» оставил бы камеру писать дальше.
    private var recordingRequested = false

    func startRecording(to url: URL) {
        queue.async {
            self.recordingRequested = true
            self.output.startRecording(to: url, recordingDelegate: self)
        }
    }

    /// completion приходит, когда файл дописан.
    func stopRecording(completion: @escaping () -> Void) {
        queue.async {
            guard self.recordingRequested else {
                completion()
                return
            }
            self.onFinish = completion
            self.output.stopRecording()
            // Если делегат так и не ответит, не оставляем интерфейс висеть на «Сохраняю».
            self.queue.asyncAfter(deadline: .now() + 6) {
                let done = self.onFinish
                self.onFinish = nil
                done?()
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        // AVFoundation иногда передаёт ошибку, хотя файл дописан нормально.
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

// MARK: - Экран (+ микрофон) в .mov

final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private var recording: SCRecordingOutput?
    private let lock = NSLock()
    private var finished = false
    private(set) var lastError: Error?
    /// Вызывается, если запись экрана остановили снаружи (кнопкой в строке меню или системой).
    var onStopped: (() -> Void)?

    private func setFinished(_ value: Bool) {
        lock.lock(); finished = value; lock.unlock()
    }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    func start(to url: URL, withMic: Bool) async throws {
        let content = try await SCShareableContent.current
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw RecorderError("Экран не найден")
        }
        // Окно суфлера вырезается из записи: исключаем всё наше приложение.
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.capturesAudio = false
        config.captureMicrophone = withMic

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let outConfig = SCRecordingOutputConfiguration()
        outConfig.outputURL = url
        outConfig.outputFileType = .mov
        // H.264 читается везде, но не тянет больше 4096 px по ширине.
        outConfig.videoCodecType = config.width > 4096 ? .hevc : .h264
        let out = SCRecordingOutput(configuration: outConfig, delegate: self)
        try stream.addRecordingOutput(out)

        setFinished(false)
        lastError = nil
        try await stream.startCapture()
        self.stream = stream
        self.recording = out
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        // Ждём, пока файл допишется (не дольше 5 секунд).
        for _ in 0..<50 where !isFinished {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        self.stream = nil
        self.recording = nil
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
