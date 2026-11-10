import AppKit
import SwiftUI

/// Scripted demo: the app plays a timeline by itself (pointer, clicks, mode changes) on a clean
/// backdrop and records only its own windows, so nothing from the real desktop gets into the film.
/// Used to make the product video; never runs for a normal launch.
///
///   DEMOSUFLER_DEMO=/path/timeline.json DEMOSUFLER_DEMO_OUT=/path/out ./demosufler-dev
enum Demo {
    private static let env = ProcessInfo.processInfo.environment
    static let timelinePath = env["DEMOSUFLER_DEMO"]
    static var active: Bool { timelinePath != nil }
    /// Show the demo windows on top instead of hiding them behind the desktop picture.
    static var visible: Bool { env["DEMOSUFLER_DEMO_VISIBLE"] != nil }
    static var outputDir: URL {
        URL(fileURLWithPath: env["DEMOSUFLER_DEMO_OUT"] ?? NSTemporaryDirectory(), isDirectory: true)
    }
}

/// Where the controls are, in window coordinates with the origin in the top left corner.
final class Anchors {
    static let shared = Anchors()
    var panel: [String: CGRect] = [:]
    var backdrop: [String: CGRect] = [:]
}

extension View {
    /// Remembers where this control is, so the demo pointer can find it. Does nothing outside the demo.
    @ViewBuilder
    func demoAnchor(_ name: String, backdrop: Bool = false) -> some View {
        if Demo.active {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                if backdrop { Anchors.shared.backdrop[name] = frame } else { Anchors.shared.panel[name] = frame }
            }
        } else {
            self
        }
    }
}

// MARK: - Backdrop

final class DemoStage: ObservableObject {
    @Published var title = ""
    @Published var subtitle = ""
    @Published var card = false
    @Published var slide = 0
    @Published var live = false
}

struct BackdropView: View {
    @ObservedObject var stage: DemoStage
    /// The prompter's frame on this backdrop (origin in the top left corner).
    let panelFrame: CGRect
    private var panelBottom: CGFloat { panelFrame.maxY }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.11), Color(white: 0.03)], startPoint: .top, endPoint: .bottom)

            // A bright document right behind the prompter: it only shows when the prompter is see-through.
            VStack(alignment: .leading, spacing: 13) {
                ForEach([0.5, 0.86, 0.78, 0.9, 0.62, 0.84, 0.7], id: \.self) { width in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.black.opacity(0.22))
                        .frame(width: (panelFrame.width - 190) * width, height: 13)
                }
            }
            .padding(30)
            .frame(width: panelFrame.width - 110, height: panelFrame.height - 60, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.93)))
            .position(x: panelFrame.midX, y: panelFrame.midY)

            // The camera above the prompter.
            HStack(spacing: 8) {
                Circle().fill(Color(white: 0.22)).frame(width: 11, height: 11)
                    .overlay(Circle().fill(Color(white: 0.06)).frame(width: 5, height: 5))
                if stage.live {
                    Circle().fill(Color.white).frame(width: 5, height: 5)
                }
            }
            .frame(width: 200, height: 30)
            .background(
                UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11, style: .continuous)
                    .fill(Color.black)
            )

            VStack(spacing: 16) {
                Text(stage.title)
                    .font(.system(size: 58, weight: .bold))
                    .foregroundStyle(Color.white)
                    .contentTransition(.opacity)
                Text(stage.subtitle)
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .contentTransition(.opacity)
                if stage.card {
                    MockApp(stage: stage)
                        .padding(.top, 22)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 80)
            .padding(.top, panelBottom + (stage.title.isEmpty ? 40 : (stage.card ? 44 : 150)))
            .animation(.easeOut(duration: 0.4), value: stage.title)
            .animation(.easeOut(duration: 0.4), value: stage.card)
        }
        .ignoresSafeArea()
    }
}

/// A stand-in for "whatever is on your screen": a small deck with three slides.
struct MockApp: View {
    @ObservedObject var stage: DemoStage

    private let names = ["Overview", "Growth", "Roadmap"]
    private let bars: [[CGFloat]] = [
        [0.35, 0.5, 0.42, 0.68, 0.6, 0.86],
        [0.2, 0.32, 0.5, 0.64, 0.82, 1.0],
        [0.9, 0.55, 0.7, 0.4, 0.62, 0.3],
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.22)).frame(width: 10, height: 10) }
                Spacer()
                ForEach(names.indices, id: \.self) { index in
                    Text(names[index])
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(stage.slide == index ? Color.black : Color.white.opacity(0.7))
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(Capsule().fill(stage.slide == index ? Color.white : Color.white.opacity(0.1)))
                        .demoAnchor("mock.tab\(index)", backdrop: true)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Color.white.opacity(0.05))

            HStack(alignment: .bottom, spacing: 34) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(names[stage.slide])
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Color.white)
                        .contentTransition(.opacity)
                    ForEach([190, 150, 170, 110], id: \.self) { width in
                        RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.16)).frame(width: CGFloat(width), height: 10)
                    }
                    Spacer(minLength: 0)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    ForEach(bars[stage.slide].indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(index == bars[stage.slide].count - 1 ? 1 : 0.5))
                            .frame(width: 34, height: 180 * bars[stage.slide][index])
                    }
                }
                .frame(height: 180, alignment: .bottom)
                .demoAnchor("mock.chart", backdrop: true)
            }
            .padding(26)
            .animation(.spring(duration: 0.5), value: stage.slide)
        }
        .frame(width: 640, height: 300)
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// Stand-in for the camera picture (the demo never opens the real camera).
struct DemoFace: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.34), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
            Image(systemName: "person.fill")
                .font(.system(size: 62))
                .foregroundStyle(Color.white.opacity(0.82))
                .offset(y: 16)
        }
    }
}

// MARK: - Director

struct DemoAction: Decodable {
    var t: Double
    var op: String
    var target: String?
    var value: Double?
    var text: String?
    var sub: String?
    var dur: Double?
    var x: Double?
    var y: Double?
    var scale: Double?
}

final class DemoDirector {
    private let model: AppModel
    private let panel: NSWindow
    private let backdrop: NSWindow
    private let stage: DemoStage
    private let recorder = ScreenRecorder()
    private var actions: [DemoAction] = []
    private var next = 0
    private var t0: CFTimeInterval = 0
    private var timer: Timer?
    private var cursor = CGPoint(x: 0.62, y: 0.78)
    private var move: (from: CGPoint, to: CGPoint, start: Double, dur: Double)?
    private var ramps: [(key: String, from: Double, to: Double, start: Double, dur: Double)] = []
    private var track = CursorTrack(samples: [], clicks: [], drawCursor: true, zooms: [], captions: [])
    private var finished = false

    private static let ranges: [String: ClosedRange<Double>] = [
        "speed": 5...120, "size": 16...52, "transparency": 0...0.85,
    ]

    init(model: AppModel, panel: NSWindow, backdrop: NSWindow, stage: DemoStage) {
        self.model = model
        self.panel = panel
        self.backdrop = backdrop
        self.stage = stage
    }

    func run() {
        guard let path = Demo.timelinePath,
              let data = FileManager.default.contents(atPath: path),
              let list = try? JSONDecoder().decode([DemoAction].self, from: data) else {
            print("demo: cannot read the timeline")
            exit(2)
        }
        actions = list.sorted { $0.t < $1.t }
        // Things that must be in place before the first frame.
        while next < actions.count, actions[next].t < 0 {
            perform(actions[next], now: 0)
            next += 1
        }
        try? FileManager.default.createDirectory(at: Demo.outputDir, withIntermediateDirectories: true)
        let movie = Demo.outputDir.appendingPathComponent("demo_screen.mov")
        try? FileManager.default.removeItem(at: movie)

        var options = ScreenOptions()
        options.microphone = false
        options.fps = 60
        options.showsCursor = false
        options.onlyWindows = [CGWindowID(panel.windowNumber), CGWindowID(backdrop.windowNumber)]

        // Give the layout a moment, then roll.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            Task { @MainActor in
                do {
                    try await self.recorder.start(to: movie, options: options)
                } catch {
                    print("demo: recording failed: \(error.localizedDescription)")
                    exit(3)
                }
                self.t0 = self.recorder.startedAt
                let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        }
    }

    private func tick() {
        guard !finished else { return }
        let now = CACurrentMediaTime() - t0
        while next < actions.count, actions[next].t <= now {
            perform(actions[next], now: now)
            next += 1
            if finished { return }
        }

        if let m = move {
            let k = Self.ease((now - m.start) / m.dur)
            cursor = CGPoint(x: m.from.x + (m.to.x - m.from.x) * k, y: m.from.y + (m.to.y - m.from.y) * k)
            if now >= m.start + m.dur { move = nil }
        }
        for ramp in ramps {
            let k = Self.ease((now - ramp.start) / ramp.dur)
            let value = ramp.from + (ramp.to - ramp.from) * k
            set(ramp.key, value)
            // The pointer drags the slider knob.
            if let p = knob(ramp.key, value: value) { cursor = p }
        }
        ramps.removeAll { now >= $0.start + $0.dur }

        track.samples.append(CursorSample(t: now, x: cursor.x, y: cursor.y))
    }

    private static func ease(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    // MARK: Coordinates

    /// A point of a window (top left origin) as a 0…1 position on the display.
    private func normalized(_ point: CGPoint, in window: NSWindow) -> CGPoint {
        let screen = NSScreen.screens.first?.frame ?? window.frame
        let x = window.frame.minX - screen.minX + point.x
        let y = (screen.maxY - window.frame.maxY) + point.y
        return CGPoint(x: x / screen.width, y: y / screen.height)
    }

    private func frame(of target: String) -> (CGRect, NSWindow)? {
        if let f = Anchors.shared.panel[target] { return (f, panel) }
        if let f = Anchors.shared.backdrop[target] { return (f, backdrop) }
        return nil
    }

    private func point(for action: DemoAction) -> CGPoint? {
        if let target = action.target, let (f, window) = frame(of: target) {
            let p = CGPoint(x: f.minX + f.width * (action.x ?? 0.5), y: f.minY + f.height * (action.y ?? 0.5))
            return normalized(p, in: window)
        }
        if action.target == nil, let x = action.x, let y = action.y { return CGPoint(x: x, y: y) }
        return nil
    }

    private func knob(_ key: String, value: Double) -> CGPoint? {
        guard let range = Self.ranges[key], let (f, window) = frame(of: key) else { return nil }
        let k = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        let p = CGPoint(x: f.minX + 8 + (f.width - 16) * k, y: f.maxY - 9)
        return normalized(p, in: window)
    }

    private func get(_ key: String) -> Double {
        switch key {
        case "speed": return model.speed
        case "size": return model.fontSize
        default: return model.transparency
        }
    }

    private func set(_ key: String, _ value: Double) {
        switch key {
        case "speed": model.speed = value
        case "size": model.fontSize = value
        default: model.transparency = value
        }
    }

    // MARK: Actions

    private func perform(_ a: DemoAction, now: Double) {
        switch a.op {
        case "caption":
            // Captions are drawn by the renderer, under the recording, so zooming never hides them.
            track.captions?.append(Caption(t: max(0, now), title: a.text ?? "", sub: a.sub ?? ""))
            if let v = a.value { stage.card = v > 0 }
        case "move":
            if let p = point(for: a) { move = (cursor, p, now, max(0.05, a.dur ?? 0.6)) }
        case "grab":
            if let key = a.target, let p = knob(key, value: get(key)) { move = (cursor, p, now, max(0.05, a.dur ?? 0.5)) }
        case "set":
            if let key = a.target, let to = a.value { set(key, to) }
        case "ramp":
            if let key = a.target, let to = a.value {
                ramps.append((key, get(key), to, now, max(0.05, a.dur ?? 0.8)))
            }
        case "click":
            track.clicks.append(CursorSample(t: now, x: cursor.x, y: cursor.y))
            if let target = a.target { act(target) }
        case "act":
            if let target = a.target { act(target) }
        case "zoom":
            closeZoom(at: now)
            let p = point(for: a)
            track.zooms?.append(ZoomSegment(start: now, end: .greatestFiniteMagnitude, scale: a.scale ?? 1.6,
                                            x: p.map { Double($0.x) }, y: p.map { Double($0.y) }))
        case "unzoom":
            closeZoom(at: now)
        case "phase":
            setPhase(a.text ?? "idle")
        case "elapsed":
            model.elapsed = Int(a.value ?? 0)
        case "status":
            model.say(a.text ?? "")
        case "script":
            if let text = a.text { model.script = text }
        case "update":
            if let version = a.text, !version.isEmpty {
                model.update = .available(UpdateInfo(version: version, zipURL: Config.releasesPage, pageURL: Config.releasesPage))
            } else {
                model.update = .none
            }
        case "access":
            let on = (a.value ?? 1) > 0
            switch a.target {
            case "camera": model.cameraAccess = on ? .granted : .notAsked
            case "mic": model.micAccess = on ? .granted : .notAsked
            default: model.screenAccess = on
            }
        case "setup":
            if (a.value ?? 1) > 0 { model.openSetup() } else { model.closeSetup() }
        case "live":
            stage.live = (a.value ?? 1) > 0
        case "end":
            finish(at: now)
        default:
            print("demo: unknown op \(a.op)")
        }
    }

    private func act(_ target: String) {
        switch target {
        case "play": model.scroller.play()
        case "pause": model.scroller.pause()
        case "reset": model.scroller.pause(); model.scroller.reset()
        case "edit": model.editing.toggle()
        case "bubble": model.launchBubble.toggle()
        case "setup.start": model.closeSetup()
        case "update": model.update = .installing(UpdateInfo(version: "", zipURL: Config.releasesPage, pageURL: Config.releasesPage))
        default:
            if target.hasPrefix("mode."), let mode = Mode(rawValue: String(target.dropFirst(5))) {
                model.mode = mode
            } else if target.hasPrefix("lang."), let lang = Lang(rawValue: String(target.dropFirst(5))) {
                model.lang = lang
            } else if target.hasPrefix("mock.tab"), let index = Int(target.dropFirst(8)) {
                stage.slide = index
            }
        }
    }

    private func setPhase(_ name: String) {
        if name.hasPrefix("countdown"), let n = Int(name.dropFirst(9)) {
            model.phase = .countdown(n)
        } else if name.hasPrefix("render"), let n = Int(name.dropFirst(6)) {
            model.phase = .rendering(n)
        } else if name == "recording" {
            model.phase = .recording
        } else if name == "saving" {
            model.phase = .saving
        } else {
            model.phase = .idle
        }
    }

    private func closeZoom(at now: Double) {
        guard let last = track.zooms?.indices.last, track.zooms?[last].end == .greatestFiniteMagnitude else { return }
        track.zooms?[last].end = now
    }

    private func finish(at now: Double) {
        finished = true
        timer?.invalidate()
        closeZoom(at: now)
        Task { @MainActor in
            await self.recorder.stop()
            let file = Demo.outputDir.appendingPathComponent("demo_track.json")
            if let data = try? JSONEncoder().encode(self.track) { try? data.write(to: file) }
            print("demo: done, \(self.track.samples.count) cursor samples, \(self.track.clicks.count) clicks")
            exit(self.recorder.lastError == nil ? 0 : 4)
        }
    }
}
