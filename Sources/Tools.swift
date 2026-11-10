import AVFoundation
import AppKit

/// Command line helpers. They are how the recording and rendering code gets tested without
/// clicking through the interface, and how the product video is put together.
///
///   --probe <file>                         tracks, size, frame rate, duration
///   --frame <file> <seconds> <out.png>     save one frame
///   --render <screen.mov> --track <json> --out <mp4> [--size 1920x1080] [--fps 60]
///            [--bitrate 12000000] [--voice <json>] [--camera <mov>] [--camera-offset <s>]
///   --selftest <folder>                    record the screen for a few seconds, render, check
///   --check-dark <file>                    list stretches of pure black frames
///   --plan <track.json> <seconds>          print the camera moves for a pointer track
enum Tools {
    static let commands: Set<String> = ["--probe", "--frame", "--render", "--selftest", "--check-dark", "--plan"]

    private struct VoiceClip: Decodable {
        var file: String
        var at: Double
    }

    static func run(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        do {
            switch args[0] {
            case "--probe":
                guard args.count > 1 else { return usage() }
                print(await MediaTools.describe(URL(fileURLWithPath: args[1])))
                return 0

            case "--frame":
                guard args.count > 3, let time = Double(args[2]) else { return usage() }
                try await MediaTools.saveFrame(of: URL(fileURLWithPath: args[1]), at: time, to: URL(fileURLWithPath: args[3]))
                return 0

            case "--render":
                guard args.count > 1, let trackPath = value("--track"), let out = value("--out") else { return usage() }
                let data = try Data(contentsOf: URL(fileURLWithPath: trackPath))
                let track = try JSONDecoder().decode(CursorTrack.self, from: data)
                var options = LaunchOptions()
                if let size = value("--size")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                    options.canvas = CGSize(width: size[0], height: size[1])
                }
                if let fps = value("--fps").flatMap({ Int32($0) }) { options.fps = fps }
                if let bitrate = value("--bitrate").flatMap({ Int($0) }) { options.bitrate = bitrate }
                if let points = NSScreen.screens.first?.frame.size, points.width > 0 { options.displayPoints = points }
                if let camera = value("--camera") {
                    options.camera = URL(fileURLWithPath: camera)
                    options.cameraOffset = value("--camera-offset").flatMap { Double($0) } ?? 0
                }
                if let voicePath = value("--voice") {
                    let clips = try JSONDecoder().decode([VoiceClip].self, from: Data(contentsOf: URL(fileURLWithPath: voicePath)))
                    options.soundtrack = try await MediaTools.soundtrack(clips: clips.map { (URL(fileURLWithPath: $0.file), $0.at) })
                }
                let started = Date()
                var shown = -1
                try await LaunchRenderer.render(screen: URL(fileURLWithPath: args[1]), track: track,
                                                output: URL(fileURLWithPath: out), options: options) { value in
                    let step = Int(value * 10)
                    if step != shown { shown = step; print("render \(step * 10)%") }
                }
                print(String(format: "rendered in %.1fs", Date().timeIntervalSince(started)))
                print(await MediaTools.describe(URL(fileURLWithPath: out)))
                return 0

            case "--plan":
                // Prints what the camera would do for a pointer track, without rendering anything.
                guard args.count > 2, let length = Double(args[2]) else { return usage() }
                let track = try JSONDecoder().decode(CursorTrack.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
                let maxZoom = LaunchOptions().maxZoom
                for shot in CameraPath.shots(for: track, duration: length, maxZoom: maxZoom) {
                    print(String(format: "shot %.2f–%.2fs  zoom %.2f  centre %.2f,%.2f  clicks %d",
                                 shot.start, shot.end, shot.scale, shot.cx, shot.cy, shot.clicks.count))
                }
                let fps = 30.0
                let path = CameraPath.make(track: track, duration: length, frames: Int(length * fps), fps: fps, maxZoom: maxZoom)
                var line = ""
                for i in stride(from: 0, to: path.zoom.count, by: Int(fps / 2)) {
                    line += String(format: "%.1fs:%.2f@%.2f,%.2f  ", Double(i) / fps, path.zoom[i], path.fx[i], path.fy[i])
                }
                print(line)
                return 0

            case "--check-dark":
                // Fails when the video has stretches of pure black (a capture that went wrong).
                guard args.count > 1 else { return usage() }
                let spans = try await MediaTools.darkSpans(in: URL(fileURLWithPath: args[1]))
                if spans.isEmpty { print("no dark stretches"); return 0 }
                print("dark: " + spans.map { String(format: "%.1f–%.1fs", $0.0, $0.1) }.joined(separator: ", "))
                return 2

            case "--selftest":
                guard args.count > 1 else { return usage() }
                return try await selfTest(folder: URL(fileURLWithPath: args[1], isDirectory: true),
                                          seconds: value("--seconds").flatMap { Double($0) } ?? 4)

            default:
                return usage()
            }
        } catch {
            print("FAIL \(error.localizedDescription)")
            return 1
        }
    }

    private static func usage() -> Int32 {
        print("usage: --probe <file> | --frame <file> <t> <png> | --render <mov> --track <json> --out <mp4> | --selftest <folder>")
        return 64
    }

    /// The real path a Launch recording takes, without the interface: record the display with the
    /// pointer tracker running, then render. Two made-up clicks are added so the zoom code runs.
    private static func selfTest(folder: URL, seconds: Double) async throws -> Int32 {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let screenURL = folder.appendingPathComponent("selftest_screen.mov")
        let outURL = folder.appendingPathComponent("selftest_launch.mp4")
        try? FileManager.default.removeItem(at: screenURL)

        let recorder = ScreenRecorder()
        let tracker = CursorTracker()
        var options = ScreenOptions()
        options.microphone = false
        options.fps = 60
        let frame = await MainActor.run { NSScreen.screens.first?.frame ?? .zero }
        await MainActor.run { tracker.start(displayFrame: frame) }
        try await recorder.start(to: screenURL, options: options)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await recorder.stop()
        if let error = recorder.lastError { throw error }
        var track = await MainActor.run { tracker.stop(videoStart: recorder.startedAt) }
        let sampled = track.samples.count
        track.clicks.append(CursorSample(t: seconds * 0.3, x: 0.3, y: 0.3))
        track.clicks.append(CursorSample(t: seconds * 0.45, x: 0.7, y: 0.6))

        var launch = LaunchOptions()
        if frame.width > 0 { launch.displayPoints = frame.size }
        let started = Date()
        try await LaunchRenderer.render(screen: screenURL, track: track, output: outURL, options: launch) { _ in }
        let took = Date().timeIntervalSince(started)

        let source = AVURLAsset(url: screenURL)
        let result = AVURLAsset(url: outURL)
        let sourceLength = try await source.load(.duration).seconds
        let resultLength = try await result.load(.duration).seconds
        let size = try await result.loadTracks(withMediaType: .video).first?.load(.naturalSize) ?? .zero
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        print(String(format: "screen %.2fs, launch %.2fs %dx%d, %d KB, %d cursor samples, rendered in %.1fs",
                     sourceLength, resultLength, Int(size.width), Int(size.height), bytes / 1024, sampled, took))

        let ok = sourceLength > seconds * 0.6
            && abs(resultLength - sourceLength) < 0.3
            && size == launch.canvas
            && bytes > 50_000
            && sampled > Int(seconds * 30)
        print(ok ? "PASS" : "FAIL")
        return ok ? 0 : 1
    }
}
