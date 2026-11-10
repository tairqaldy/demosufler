import AVFoundation
import AppKit
import SwiftUI

enum Mode: String, CaseIterable {
    case camera, both, screen, launch

    var title: String {
        switch self {
        case .camera: return tr("Camera", "Камера")
        case .both: return tr("Both", "Оба")
        case .screen: return tr("Screen", "Экран")
        case .launch: return tr("Launch", "Ролик")
        }
    }

    var hint: String {
        switch self {
        case .camera: return tr("One file: camera and microphone", "Один файл: камера и микрофон")
        case .both: return tr("Two files in parallel: camera and screen", "Два файла параллельно: камера и экран")
        case .screen: return tr("One file: screen and microphone", "Один файл: экран и микрофон")
        case .launch: return tr("Finished video: zooms on clicks, clean background",
                                "Готовый ролик: зум по кликам, чистый фон")
        }
    }

    var usesScreen: Bool { self != .camera }
}

enum Phase: Equatable {
    case idle
    case countdown(Int)
    case recording
    case saving
    /// Building the launch video, 0…100.
    case rendering(Int)
}

/// What a click on the status line does.
enum StatusAction {
    case reveal([URL])
}

/// State of a system permission.
enum Access {
    case granted, notAsked, denied
}

struct Paragraph: Identifiable, Equatable {
    let id: Int
    let text: String
    let isCue: Bool
}

// MARK: - Text scrolling

final class Scroller: ObservableObject {
    /// Not published on purpose: the prompter redraws itself through `onChange`,
    /// so 120 updates a second never go through SwiftUI.
    var offset: CGFloat = 0 { didSet { onChange?() } }
    var onChange: (() -> Void)?
    @Published private(set) var playing = false
    var speed: CGFloat = 16        // points per second
    var maxOffset: CGFloat = 0
    private var timer: Timer?
    private var last = CACurrentMediaTime()

    func play() {
        if playing { return }
        if offset >= maxOffset - 1 { offset = 0 }
        playing = true
        last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        if playing { playing = false }
        timer?.invalidate()
        timer = nil
    }

    func toggle() { playing ? pause() : play() }

    func reset() { offset = 0 }

    func nudge(_ dy: CGFloat) {
        offset = min(max(0, offset + dy), max(0, maxOffset))
    }

    private func tick() {
        let now = CACurrentMediaTime()
        // After a stall never jump: move at most a tenth of a second worth of text.
        let dt = min(now - last, 0.1)
        last = now
        let next = offset + speed * CGFloat(dt)
        if next >= maxOffset {
            offset = max(0, maxOffset)
            pause()
        } else {
            offset = next
        }
    }
}

// MARK: - App state

final class AppModel: ObservableObject {
    let scroller = Scroller()
    let camera = CameraRecorder()
    let screen = ScreenRecorder()
    let tracker = CursorTracker()
    /// The scripted demo drives the interface itself: no permissions, no recorders, own settings.
    let demo = Demo.active
    private let defaults: UserDefaults

    @Published var lang: Lang {
        didSet {
            let previous = oldValue
            Lang.current = lang
            defaults.set(lang.rawValue, forKey: "lang")
            // An untouched sample text follows the language.
            if script == defaultScript(for: previous) { script = defaultScript(for: lang) }
        }
    }
    @Published var script: String { didSet { defaults.set(script, forKey: "script") } }
    @Published var speed: Double {
        didSet { scroller.speed = CGFloat(speed); defaults.set(speed, forKey: "speed") }
    }
    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: "fontSize"); updateMaxOffset() }
    }
    /// 0 = solid black background, 0.85 = almost clear. The text stays bright.
    @Published var transparency: Double {
        didSet { defaults.set(transparency, forKey: "transparency") }
    }
    @Published var mode: Mode {
        didSet {
            defaults.set(mode.rawValue, forKey: "mode")
            modeChanged()
        }
    }
    /// Launch mode: put the round camera picture into the video.
    @Published var launchBubble: Bool {
        didSet {
            defaults.set(launchBubble, forKey: "launchBubble")
            modeChanged()
        }
    }
    @Published var editing = false {
        didSet { if editing { scroller.pause() } else { scroller.reset() } }
    }
    @Published var phase: Phase = .idle
    @Published var elapsed = 0
    @Published private(set) var status = ""
    @Published private(set) var statusAction: StatusAction?
    @Published var cameraReady = false
    @Published var contentHeight: CGFloat = 0 { didSet { updateMaxOffset() } }
    @Published var update: UpdateState = .none

    // System permissions and the setup screen.
    @Published var cameraAccess: Access = .notAsked
    @Published var micAccess: Access = .notAsked
    @Published var screenAccess = false
    @Published private(set) var screenAsked = false
    @Published var showSetup = false
    private var accessTimer: Timer?
    @Published private(set) var onboarded: Bool

    private var countdownTimer: Timer?
    private var elapsedTimer: Timer?
    private var startedAt = Date()
    private var recordingMode: Mode = .camera
    private var recordingCamera = false
    private var currentURLs: [URL] = []
    private var launchURL: URL?
    private var screenStart: Task<Bool, Never>?
    private var afterSave: [() -> Void] = []

    init() {
        if demo {
            // The demo never touches the person's real settings.
            let suite = "demosufler.demo"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            defaults = UserDefaults(suiteName: suite) ?? .standard
        } else {
            defaults = .standard
        }
        let language = Lang(rawValue: defaults.string(forKey: "lang") ?? "") ?? .en
        Lang.current = language
        lang = language
        script = defaults.string(forKey: "script") ?? defaultScript(for: language)
        let savedSpeed = defaults.double(forKey: "speed")
        speed = savedSpeed > 0 ? savedSpeed : 16
        let savedSize = defaults.double(forKey: "fontSize")
        fontSize = savedSize > 0 ? savedSize : 28
        transparency = min(0.85, max(0, defaults.double(forKey: "transparency")))
        mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .camera
        launchBubble = defaults.object(forKey: "launchBubble") as? Bool ?? true
        onboarded = defaults.bool(forKey: "onboarded")
        scroller.speed = CGFloat(speed)

        // A recording can break on its own: finish the take cleanly.
        screen.onStopped = { [weak self] in
            DispatchQueue.main.async { self?.recordingBroke(tr("Screen recording was stopped", "Запись экрана остановлена")) }
        }
        camera.onFailure = { [weak self] error in
            DispatchQueue.main.async {
                self?.recordingBroke(tr("Camera: ", "Камера: ") + error.localizedDescription)
            }
        }
    }

    /// Does the selected mode record the camera?
    var usesCamera: Bool {
        switch mode {
        case .camera, .both: return true
        case .screen: return false
        case .launch: return launchBubble
        }
    }

    var outputDir: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("demosufler", isDirectory: true)
    }

    var paragraphs: [Paragraph] {
        script.split(separator: "\n", omittingEmptySubsequences: true).enumerated().compactMap { index, line in
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return nil }
            if text.hasPrefix("#") {
                let cue = text.drop(while: { $0 == "#" || $0 == " " })
                return Paragraph(id: index, text: String(cue), isCue: true)
            }
            return Paragraph(id: index, text: text, isCue: text.hasPrefix("[") && text.hasSuffix("]"))
        }
    }

    /// How long the whole text takes at the current speed.
    var estimate: String {
        guard speed > 0, scroller.maxOffset > 0 else { return "" }
        return "≈ " + Self.clock(Int((Double(scroller.maxOffset) / speed).rounded()))
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func updateMaxOffset() {
        scroller.maxOffset = max(0, contentHeight - CGFloat(fontSize) * 1.5)
    }

    // MARK: Status line

    func say(_ text: String, action: StatusAction? = nil) {
        statusAction = action
        status = text
    }

    func runStatusAction() {
        switch statusAction {
        case .reveal(let urls):
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case nil:
            break
        }
    }

    // MARK: Permissions and the setup screen

    /// First launch: show the setup screen if anything is missing, start the camera if allowed.
    func start() {
        if demo {
            cameraAccess = .granted
            micAccess = .granted
            screenAccess = true
            return
        }
        refreshAccess()
        if !onboarded || missingAccess { openSetup() }
        updateCamera()
    }

    private func modeChanged() {
        say("")
        if demo { return }
        refreshAccess()
        if missingAccess { openSetup() }
        updateCamera()
    }

    private static func access(_ type: AVMediaType) -> Access {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    /// Is anything missing for the selected mode?
    var missingAccess: Bool {
        (usesCamera && cameraAccess != .granted) || micAccess != .granted || (mode.usesScreen && !screenAccess)
    }

    func refreshAccess() {
        if demo { return }
        let cam = Self.access(.video)
        let mic = Self.access(.audio)
        let scr = CGPreflightScreenCaptureAccess()
        let cameraJustGranted = cam == .granted && cameraAccess != .granted
        if cam != cameraAccess { cameraAccess = cam }
        if mic != micAccess { micAccess = mic }
        if scr != screenAccess { screenAccess = scr }
        if cameraJustGranted { updateCamera() }
    }

    func openSetup() {
        if editing { editing = false }
        if !showSetup { showSetup = true }
        if demo { return }
        accessTimer?.invalidate()
        // While the setup screen is open, watch what the person has already allowed.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshAccess() }
        RunLoop.main.add(t, forMode: .common)
        accessTimer = t
    }

    func closeSetup() {
        accessTimer?.invalidate()
        accessTimer = nil
        showSetup = false
        defaults.set(true, forKey: "onboarded")
        onboarded = true
        if demo { return }
        refreshAccess()
        updateCamera()
    }

    func askCamera() {
        switch cameraAccess {
        case .notAsked:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async {
                    self.refreshAccess()
                    // Ask for the microphone right after: one click instead of two.
                    if self.micAccess == .notAsked { self.askMic() }
                }
            }
        case .denied: openPrivacySettings("Privacy_Camera")
        case .granted: break
        }
    }

    func askMic() {
        switch micAccess {
        case .notAsked:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.refreshAccess() }
            }
        case .denied: openPrivacySettings("Privacy_Microphone")
        case .granted: break
        }
    }

    /// Screen recording can only be switched on by hand in System Settings, followed by a restart.
    func askScreen() {
        screenAsked = true
        CGRequestScreenCaptureAccess()
        openPrivacySettings("Privacy_ScreenCapture")
    }

    func relaunch() {
        camera.stop()
        Updater.relaunch()
    }

    private func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateCamera() {
        guard usesCamera else {
            if cameraReady { cameraReady = false }
            camera.stop()
            return
        }
        guard cameraAccess == .granted, !cameraReady else { return }
        camera.start { error in
            if let error {
                self.say(error.localizedDescription)
            } else if self.usesCamera {
                self.cameraReady = true
            } else {
                self.camera.stop()
            }
        }
    }

    // MARK: Recording

    func toggleRecord() {
        if demo { return }
        switch phase {
        case .idle: beginCountdown()
        case .countdown: cancelCountdown()
        case .recording: stopRecording()
        case .saving, .rendering: break
        }
    }

    private func beginCountdown() {
        if case .installing = update { return }
        refreshAccess()
        if (usesCamera && cameraAccess != .granted) || (mode.usesScreen && !screenAccess) {
            openSetup()
            return
        }
        if showSetup { closeSetup() }
        if usesCamera && !cameraReady {
            say(tr("The camera is not ready yet", "Камера ещё не готова"))
            return
        }
        editing = false
        say("")
        scroller.pause()
        scroller.reset()
        // The microphone is opened only now, three seconds before the take.
        if usesCamera && micAccess == .granted { camera.setMic(true) }
        phase = .countdown(3)
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, case .countdown(let n) = self.phase else {
                timer.invalidate()
                return
            }
            if n > 1 {
                self.phase = .countdown(n - 1)
            } else {
                timer.invalidate()
                self.startRecording()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        countdownTimer = t
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        camera.setMic(false)
        phase = .idle
    }

    private func startRecording() {
        let dir = outputDir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            phase = .idle
            camera.setMic(false)
            say(tr("Cannot create the recordings folder: ", "Не могу создать папку для записей: ") + error.localizedDescription)
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: Date())

        recordingMode = mode
        recordingCamera = usesCamera
        currentURLs = []
        launchURL = nil
        screenStart = nil

        if recordingCamera {
            let url = dir.appendingPathComponent("\(stamp)_camera.mov")
            camera.startRecording(to: url)
            currentURLs.append(url)
        }
        if recordingMode.usesScreen {
            let url = dir.appendingPathComponent("\(stamp)_screen.mov")
            currentURLs.append(url)
            let needsScreen = recordingMode != .both
            var options = ScreenOptions()
            options.microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if recordingMode == .launch {
                options.fps = 60
                launchURL = dir.appendingPathComponent("\(stamp)_launch.mp4")
                tracker.start(displayFrame: NSScreen.screens.first?.frame ?? .zero)
            }
            screenStart = Task {
                do {
                    try await self.screen.start(to: url, options: options)
                    return true
                } catch {
                    await MainActor.run {
                        self.say(tr("The screen is not being recorded: ", "Экран не записывается: ") + error.localizedDescription)
                        if needsScreen { self.stopRecording() }
                    }
                    return false
                }
            }
        }

        phase = .recording
        elapsed = 0
        startedAt = Date()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let seconds = Int(Date().timeIntervalSince(self.startedAt))
            if seconds != self.elapsed { self.elapsed = seconds }
        }
        RunLoop.main.add(t, forMode: .common)
        elapsedTimer = t
        scroller.play()
    }

    private func recordingBroke(_ message: String) {
        guard phase == .recording else { return }
        say(message)
        stopRecording()
    }

    func stopRecording(then: (() -> Void)? = nil) {
        // Already saving: just wait (quitting now would cut off an unfinished file).
        if phase == .saving {
            if let then { afterSave.append(then) }
            return
        }
        guard phase == .recording else {
            then?()
            return
        }
        if let then { afterSave.append(then) }
        phase = .saving
        scroller.pause()
        elapsedTimer?.invalidate()
        let usedCamera = recordingCamera
        let urls = currentURLs
        let pendingScreen = screenStart
        let finalURL = launchURL
        Task { @MainActor in
            var screenOK = false
            if let pendingScreen, await pendingScreen.value {
                await self.screen.stop()
                screenOK = true
            }
            if usedCamera {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    self.camera.stopRecording { c.resume() }
                }
            }
            self.camera.setMic(false)
            let saved = urls.filter { url in
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                return size > 0
            }
            let track = self.tracker.stop(videoStart: self.screen.startedAt)

            // Files are safe on disk: anything waiting on the save (such as quitting) may go on.
            let waiting = self.afterSave
            self.afterSave = []

            if let finalURL, screenOK, let screenURL = saved.first(where: { $0.lastPathComponent.hasSuffix("_screen.mov") }) {
                waiting.forEach { $0() }
                let cameraURL = saved.first { $0.lastPathComponent.hasSuffix("_camera.mov") }
                self.renderLaunch(screen: screenURL, camera: cameraURL, track: track, output: finalURL)
                return
            }

            self.phase = .idle
            if saved.isEmpty {
                if self.status.isEmpty { self.say(tr("The file was not saved", "Файл не сохранился")) }
            } else if saved.count == urls.count && self.status.isEmpty {
                self.say(tr("Saved. Show in Finder", "Сохранено. Показать в Finder"), action: .reveal(saved))
            }
            waiting.forEach { $0() }
        }
    }

    /// Builds the finished launch video from the raw files. The raw files stay next to it.
    private func renderLaunch(screen screenURL: URL, camera cameraURL: URL?, track: CursorTrack, output: URL) {
        phase = .rendering(0)
        var options = LaunchOptions()
        if let frame = NSScreen.screens.first?.frame.size, frame.width > 0 { options.displayPoints = frame }
        if let cameraURL, camera.startedAt > 0, screen.startedAt > 0 {
            options.camera = cameraURL
            options.cameraOffset = camera.startedAt - screen.startedAt
        }
        Task.detached(priority: .userInitiated) {
            do {
                try await LaunchRenderer.render(screen: screenURL, track: track, output: output, options: options) { value in
                    DispatchQueue.main.async {
                        let percent = Int(value * 100)
                        if case .rendering(let shown) = self.phase, shown != percent { self.phase = .rendering(percent) }
                    }
                }
                await MainActor.run {
                    self.phase = .idle
                    self.say(tr("Launch video is ready. Show in Finder", "Ролик готов. Показать в Finder"),
                             action: .reveal([output]))
                }
            } catch {
                await MainActor.run {
                    self.phase = .idle
                    self.say(tr("Could not build the video, the raw recording is saved: ",
                                "Ролик не собрался, исходная запись сохранена: ") + error.localizedDescription,
                             action: .reveal([screenURL]))
                }
            }
        }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputDir)
    }

    // MARK: Updates

    func checkForUpdate() {
        if demo { return }
        Task {
            guard let info = await Updater.check() else { return }
            await MainActor.run {
                self.update = .available(info)
                // Build check only: installs the update without a click.
                if ProcessInfo.processInfo.environment["DEMOSUFLER_AUTOUPDATE"] != nil {
                    self.installUpdate()
                }
            }
        }
    }

    func installUpdate() {
        if demo { return }
        let info: UpdateInfo
        switch update {
        case .available(let found), .failed(let found, _): info = found
        default: return
        }
        guard phase == .idle else { return }
        guard Updater.canSelfUpdate else {
            NSWorkspace.shared.open(info.pageURL)
            return
        }
        update = .installing(info)
        Task {
            do {
                try await Updater.install(info)
                await MainActor.run {
                    self.camera.stop()
                    Updater.relaunch()
                }
            } catch {
                await MainActor.run {
                    self.update = .failed(info, error.localizedDescription)
                }
            }
        }
    }

    func openDownloadPage() {
        NSWorkspace.shared.open(Config.releasesPage)
    }
}
