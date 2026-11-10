import AppKit

/// One cursor position. `t` is seconds from the start of the screen video;
/// `x` and `y` are 0…1 across the recorded display with the origin in the top left corner.
struct CursorSample: Codable {
    var t: Double
    var x: Double
    var y: Double
}

/// A stretch of the video shown zoomed in. `start` is where the zoom-in begins and `end`
/// where the zoom-out finishes. With `x`/`y` set the camera stays on that point, otherwise
/// it follows the cursor.
struct ZoomSegment: Codable {
    var start: Double
    var end: Double
    var scale: Double
    var x: Double?
    var y: Double?
}

/// A title shown under the recording from `t` until the next caption.
struct Caption: Codable {
    var t: Double
    var title: String
    var sub: String
}

/// Everything the launch video renderer needs to know about the pointer.
struct CursorTrack: Codable {
    var samples: [CursorSample] = []
    var clicks: [CursorSample] = []
    /// true when the cursor is not in the video itself and has to be drawn by the renderer.
    var drawCursor = false
    /// Explicit zooms. nil = work them out from the clicks.
    var zooms: [ZoomSegment]?
    /// Titles under the recording (used by the product video).
    var captions: [Caption]?

    func position(at t: Double) -> CursorSample? {
        guard let first = samples.first else { return clicks.last { $0.t <= t } ?? clicks.first }
        if t <= first.t { return first }
        guard let last = samples.last, t < last.t else { return samples.last }
        // Binary search for the pair of samples around t, then interpolate.
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        let k = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
        return CursorSample(t: t, x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }
}

/// Follows the real pointer during a recording. Uses polling only, so it needs no permissions.
final class CursorTracker {
    private var timer: Timer?
    private var frame = CGRect.zero
    private var samples: [CursorSample] = []
    private var clicks: [CursorSample] = []
    private var wasDown = false

    /// `displayFrame` is the recorded display in AppKit screen coordinates.
    func start(displayFrame: CGRect) {
        stopTimer()
        frame = displayFrame
        samples = []
        clicks = []
        wasDown = false
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard frame.width > 0, frame.height > 0 else { return }
        let p = NSEvent.mouseLocation
        let sample = CursorSample(
            t: CACurrentMediaTime(),
            x: Double((p.x - frame.minX) / frame.width),
            y: Double(1 - (p.y - frame.minY) / frame.height)
        )
        samples.append(sample)
        let down = NSEvent.pressedMouseButtons & 1 == 1
        // A click counts only when it lands on the recorded display.
        if down && !wasDown && (0...1).contains(sample.x) && (0...1).contains(sample.y) {
            clicks.append(sample)
        }
        wasDown = down
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Stops and returns the track with times counted from `videoStart` (host time).
    func stop(videoStart: CFTimeInterval) -> CursorTrack {
        stopTimer()
        func shifted(_ list: [CursorSample]) -> [CursorSample] {
            list.compactMap { s in
                let t = s.t - videoStart
                return t >= 0 ? CursorSample(t: t, x: s.x, y: s.y) : nil
            }
        }
        return CursorTrack(samples: shifted(samples), clicks: shifted(clicks))
    }

    func cancel() {
        stopTimer()
        samples = []
        clicks = []
    }
}
