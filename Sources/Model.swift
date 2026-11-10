import AVFoundation
import AppKit
import SwiftUI

enum Mode: String, CaseIterable {
    case camera, both, screen

    var title: String {
        switch self {
        case .camera: return "Камера"
        case .both: return "Оба"
        case .screen: return "Экран"
        }
    }

    var hint: String {
        switch self {
        case .camera: return "Один файл: камера и микрофон"
        case .both: return "Два файла параллельно: камера и экран"
        case .screen: return "Один файл: экран и микрофон"
        }
    }

    var usesCamera: Bool { self != .screen }
    var usesScreen: Bool { self != .camera }
}

enum Phase: Equatable {
    case idle
    case countdown(Int)
    case recording
    case saving
}

/// Что произойдёт по клику на строку статуса.
enum StatusAction {
    case screenSettings
    case reveal([URL])
}

struct Paragraph: Identifiable {
    let id: Int
    let text: String
    let isCue: Bool
}

// MARK: - Прокрутка текста

final class Scroller: ObservableObject {
    @Published var offset: CGFloat = 0
    @Published private(set) var playing = false
    var speed: CGFloat = 16        // пунктов в секунду
    var maxOffset: CGFloat = 0
    private var timer: Timer?
    private var last = CACurrentMediaTime()

    func play() {
        if playing { return }
        if offset >= maxOffset - 1 { offset = 0 }
        playing = true
        last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        playing = false
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
        let dt = now - last
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

// MARK: - Состояние приложения

final class AppModel: ObservableObject {
    let scroller = Scroller()
    let camera = CameraRecorder()
    let screen = ScreenRecorder()
    private let defaults = UserDefaults.standard

    @Published var script: String { didSet { defaults.set(script, forKey: "script") } }
    @Published var speed: Double {
        didSet { scroller.speed = CGFloat(speed); defaults.set(speed, forKey: "speed") }
    }
    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: "fontSize"); updateMaxOffset() }
    }
    /// 0 = сплошной чёрный фон, 0.85 = почти прозрачный. Текст остаётся ярким.
    @Published var transparency: Double {
        didSet { defaults.set(transparency, forKey: "transparency") }
    }
    @Published var mode: Mode {
        didSet {
            defaults.set(mode.rawValue, forKey: "mode")
            say("")
            updateDevices()
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

    private var countdownTimer: Timer?
    private var elapsedTimer: Timer?
    private var startedAt = Date()
    private var recordingMode: Mode = .camera
    private var currentURLs: [URL] = []
    private var screenStart: Task<Bool, Never>?
    private var askedForScreen = false
    private var afterSave: [() -> Void] = []

    init() {
        script = defaults.string(forKey: "script") ?? defaultScript
        let savedSpeed = defaults.double(forKey: "speed")
        speed = savedSpeed > 0 ? savedSpeed : 16
        let savedSize = defaults.double(forKey: "fontSize")
        fontSize = savedSize > 0 ? savedSize : 28
        transparency = min(0.85, max(0, defaults.double(forKey: "transparency")))
        mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .camera
        scroller.speed = CGFloat(speed)

        // Запись могла оборваться сама: тогда аккуратно завершаем дубль.
        screen.onStopped = { [weak self] in
            DispatchQueue.main.async { self?.recordingBroke("Запись экрана остановлена") }
        }
        camera.onFailure = { [weak self] error in
            DispatchQueue.main.async { self?.recordingBroke("Камера: \(error.localizedDescription)") }
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

    /// Сколько займёт весь текст на текущей скорости.
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

    // MARK: Строка статуса

    func say(_ text: String, action: StatusAction? = nil) {
        statusAction = action
        status = text
    }

    func runStatusAction() {
        switch statusAction {
        case .screenSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .reveal(let urls):
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case nil:
            break
        }
    }

    // MARK: Камера, микрофон, доступ к экрану

    func updateDevices() {
        AVCaptureDevice.requestAccess(for: .audio) { micOK in
            DispatchQueue.main.async {
                if !micOK { self.say("Микрофон не разрешён: запись будет без звука") }
                self.updateCamera()
                if self.mode.usesScreen { self.checkScreenAccess() }
            }
        }
    }

    private func updateCamera() {
        guard mode.usesCamera else {
            camera.stop()
            cameraReady = false
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                guard ok else {
                    self.say("Нет доступа к камере. Настройки → Конфиденциальность → Камера")
                    return
                }
                self.camera.start { error in
                    if let error {
                        self.say(error.localizedDescription)
                    } else if self.mode.usesCamera {
                        self.cameraReady = true
                    } else {
                        self.camera.stop()
                    }
                }
            }
        }
    }

    @discardableResult
    private func checkScreenAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // Системное окно с просьбой показываем один раз за запуск, дальше ведём в настройки.
        if !askedForScreen {
            askedForScreen = true
            CGRequestScreenCaptureAccess()
        }
        say("Нет доступа к записи экрана. Открой настройки, включи demosufler заново и перезапусти",
            action: .screenSettings)
        return false
    }

    // MARK: Запись

    func toggleRecord() {
        switch phase {
        case .idle: beginCountdown()
        case .countdown: cancelCountdown()
        case .recording: stopRecording()
        case .saving: break
        }
    }

    private func beginCountdown() {
        if case .installing = update { return }
        if mode.usesCamera && !cameraReady {
            say("Камера ещё не готова")
            return
        }
        if mode.usesScreen && !checkScreenAccess() { return }
        editing = false
        say("")
        scroller.pause()
        scroller.reset()
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
        phase = .idle
    }

    private func startRecording() {
        let dir = outputDir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            phase = .idle
            say("Не могу создать папку для записей: \(error.localizedDescription)")
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: Date())

        recordingMode = mode
        currentURLs = []
        screenStart = nil

        if recordingMode.usesCamera {
            let url = dir.appendingPathComponent("\(stamp)_camera.mov")
            camera.startRecording(to: url)
            currentURLs.append(url)
        }
        if recordingMode.usesScreen {
            let url = dir.appendingPathComponent("\(stamp)_screen.mov")
            currentURLs.append(url)
            let screenOnly = recordingMode == .screen
            screenStart = Task {
                do {
                    try await self.screen.start(
                        to: url, withMic: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
                    return true
                } catch {
                    await MainActor.run {
                        self.say("Экран не записывается: \(error.localizedDescription)")
                        if screenOnly { self.stopRecording() }
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
            self.elapsed = Int(Date().timeIntervalSince(self.startedAt))
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
        // Уже сохраняем: просто дождёмся (иначе выход по ⌘Q оборвал бы недописанный файл).
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
        let usedCamera = recordingMode.usesCamera
        let urls = currentURLs
        let pendingScreen = screenStart
        Task { @MainActor in
            if let pendingScreen, await pendingScreen.value {
                await self.screen.stop()
            }
            if usedCamera {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    self.camera.stopRecording { c.resume() }
                }
            }
            let saved = urls.filter { url in
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                return size > 0
            }
            self.phase = .idle
            if saved.isEmpty {
                if self.status.isEmpty { self.say("Файл не сохранился") }
            } else if saved.count == urls.count && self.status.isEmpty {
                self.say("Сохранено. Показать в Finder", action: .reveal(saved))
            }
            let waiting = self.afterSave
            self.afterSave = []
            waiting.forEach { $0() }
        }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputDir)
    }

    // MARK: Обновления

    func checkForUpdate() {
        Task {
            guard let info = await Updater.check() else { return }
            await MainActor.run {
                self.update = .available(info)
                // Только для проверки сборки: ставит обновление без клика.
                if ProcessInfo.processInfo.environment["DEMOSUFLER_AUTOUPDATE"] != nil {
                    self.installUpdate()
                }
            }
        }
    }

    func installUpdate() {
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
