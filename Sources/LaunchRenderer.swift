import AVFoundation
import AppKit
import CoreImage

/// Turns a raw screen recording into a finished "launch video": the recording sits on a clean
/// background with rounded corners and a shadow, the view zooms in on clicks and follows the
/// pointer, clicks leave a ripple, and an optional camera bubble sits in the corner.
struct LaunchOptions {
    var canvas = CGSize(width: 1920, height: 1080)
    var fps: Int32 = 60
    var bitrate = 12_000_000
    var maxZoom = 1.7
    /// Size of the recorded display in points (used to size the drawn cursor).
    var displayPoints = CGSize(width: 1512, height: 982)
    var camera: URL?
    /// Camera file start minus screen file start, in seconds.
    var cameraOffset = 0.0
    /// Replacement soundtrack. nil = keep the sound recorded with the screen.
    var soundtrack: AVAsset?
}

// MARK: - Camera path (zoom and focus for every frame)

struct CameraPath {
    var zoom: [Double]
    var fx: [Double]
    var fy: [Double]

    /// Zooms derived from clicks: clicks close in time share one zoom.
    static func segments(for track: CursorTrack, duration: Double, maxZoom: Double) -> [ZoomSegment] {
        if let explicit = track.zooms { return explicit }
        var result: [ZoomSegment] = []
        var first: Double?
        var last = 0.0
        func close() {
            guard let f = first else { return }
            result.append(ZoomSegment(start: max(0, f - 0.6), end: last + 1.6, scale: maxZoom))
        }
        for click in track.clicks.sorted(by: { $0.t < $1.t }) {
            if first != nil, click.t - last < 3.2 {
                last = click.t
            } else {
                close()
                first = click.t
                last = click.t
            }
        }
        close()
        return result
    }

    static func make(track: CursorTrack, duration: Double, frames: Int, fps: Double, maxZoom: Double) -> CameraPath {
        let segments = Self.segments(for: track, duration: duration, maxZoom: maxZoom)
        var path = CameraPath(zoom: [], fx: [], fy: [])
        path.zoom.reserveCapacity(frames)
        path.fx.reserveCapacity(frames)
        path.fy.reserveCapacity(frames)

        // Two cascaded low-pass filters give an ease-in, ease-out curve with no sudden starts.
        let dt = 1 / fps
        let k = 1 - exp(-dt / 0.15)
        var z1 = 1.0, z2 = 1.0
        var x1 = 0.5, x2 = 0.5, y1 = 0.5, y2 = 0.5
        var tx = 0.5, ty = 0.5
        var active = -1

        for i in 0..<frames {
            let t = Double(i) * dt
            var targetZoom = 1.0
            // Always end the video zoomed out.
            if t < duration - 0.7,
               let index = segments.firstIndex(where: { t >= $0.start && t < $0.end }) {
                let seg = segments[index]
                targetZoom = max(1, seg.scale)
                if index != active {
                    active = index
                    if let x = seg.x, let y = seg.y {
                        tx = x; ty = y
                    } else if let c = track.clicks.first(where: { $0.t >= seg.start }) ?? track.position(at: t) {
                        tx = c.x; ty = c.y
                    }
                    // Starting from the full view: jump the focus, nobody can see it move.
                    if z2 < 1.03 { x1 = tx; x2 = tx; y1 = ty; y2 = ty }
                }
                if seg.x == nil, let c = track.position(at: t) {
                    // Follow the pointer only when it leaves the middle of the zoomed view.
                    let dead = 0.5 / targetZoom * 0.5
                    if c.x > tx + dead { tx = c.x - dead } else if c.x < tx - dead { tx = c.x + dead }
                    if c.y > ty + dead { ty = c.y - dead } else if c.y < ty - dead { ty = c.y + dead }
                }
            } else {
                active = -1
            }
            z1 += (targetZoom - z1) * k; z2 += (z1 - z2) * k
            x1 += (tx - x1) * k; x2 += (x1 - x2) * k
            y1 += (ty - y1) * k; y2 += (y1 - y2) * k
            path.zoom.append(z2)
            path.fx.append(x2)
            path.fy.append(y2)
        }
        return path
    }
}

// MARK: - Reading frames in order

private final class FrameReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var current: CMSampleBuffer?
    private var next: CMSampleBuffer?
    private let start: Double

    init(asset: AVAsset, track: AVAssetTrack, start: Double) throws {
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        self.start = start
        guard reader.startReading() else {
            throw reader.error ?? RecorderError("Cannot read the recording")
        }
        next = output.copyNextSampleBuffer()
    }

    /// The latest frame at or before `t` (seconds from the start of the track).
    func image(at t: Double) -> CIImage? {
        while let n = next, CMSampleBufferGetPresentationTimeStamp(n).seconds - start <= t + 0.0005 {
            current = n
            next = output.copyNextSampleBuffer()
        }
        if current == nil {
            current = next
            next = output.copyNextSampleBuffer()
        }
        guard let buffer = current, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        // No colour management anywhere in the renderer: pixel values go through untouched,
        // so the video looks exactly like the recording.
        return CIImage(cvPixelBuffer: pixels, options: [.colorSpace: NSNull()])
    }

    func cancel() { reader.cancelReading() }
}

// MARK: - Sprites drawn once

private enum Sprite {
    static func context(_ size: CGSize) -> CGContext {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    static func image(_ size: CGSize, _ draw: (CGContext) -> Void) -> CIImage {
        let ctx = context(size)
        draw(ctx)
        return CIImage(cgImage: ctx.makeImage()!, options: [.colorSpace: NSNull()])
    }

    /// Background gradient with the soft shadow of the recording on it.
    static func plate(canvas: CGSize, content: CGRect, radius: CGFloat) -> CIImage {
        image(canvas) { ctx in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let colors = [CGColor(gray: 0.24, alpha: 1), CGColor(gray: 0.10, alpha: 1), CGColor(gray: 0.03, alpha: 1)] as CFArray
            let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height),
                                   end: CGPoint(x: canvas.width, y: 0), options: [])
            // A faint light from the top, so the plate is not flat.
            let glow = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray,
                                  locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: canvas.width * 0.5, y: canvas.height * 1.05), startRadius: 0,
                                   endCenter: CGPoint(x: canvas.width * 0.5, y: canvas.height * 1.05),
                                   endRadius: canvas.width * 0.6, options: [])
            ctx.setShadow(offset: CGSize(width: 0, height: -canvas.height * 0.022), blur: canvas.height * 0.055,
                          color: CGColor(gray: 0, alpha: 0.6))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
    }

    /// White rounded rectangle on black: where the recording shows through.
    static func mask(size: CGSize, radius: CGFloat) -> CIImage {
        image(size) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
    }

    /// Thin border drawn over the recording, so dark recordings do not melt into the background.
    static func border(size: CGSize, radius: CGFloat) -> CIImage {
        image(size) { ctx in
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
            ctx.setLineWidth(2)
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius - 1, cornerHeight: radius - 1, transform: nil))
            ctx.strokePath()
        }
    }

    /// Title and sub-title centred in the band of height `band` at the bottom of the canvas.
    static func caption(_ caption: Caption, canvas: CGSize, band: CGFloat) -> CIImage {
        image(CGSize(width: canvas.width, height: band)) { ctx in
            let unit = canvas.height / 1080
            let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            let title = NSAttributedString(string: caption.title, attributes: [
                .font: NSFont.systemFont(ofSize: 54 * unit, weight: .bold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: centered,
            ])
            let sub = NSAttributedString(string: caption.sub, attributes: [
                .font: NSFont.systemFont(ofSize: 26 * unit, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.6),
                .paragraphStyle: centered,
            ])
            let titleHeight = 66 * unit, subHeight = 34 * unit, gap = 10 * unit
            let block = titleHeight + gap + subHeight
            let bottom = (band - block) / 2 + 6 * unit
            sub.draw(in: CGRect(x: 0, y: bottom, width: canvas.width, height: subHeight))
            title.draw(in: CGRect(x: 0, y: bottom + subHeight + gap, width: canvas.width, height: titleHeight))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static let ringSize: CGFloat = 256

    static func ring() -> CIImage {
        image(CGSize(width: ringSize, height: ringSize)) { ctx in
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(14)
            ctx.setShadow(offset: .zero, blur: 10, color: CGColor(gray: 0, alpha: 0.55))
            ctx.strokeEllipse(in: CGRect(x: 28, y: 28, width: ringSize - 56, height: ringSize - 56))
        }
    }

    static func circleMask(diameter: CGFloat) -> CIImage {
        image(CGSize(width: diameter, height: diameter)) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: diameter, height: diameter))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        }
    }

    /// Shadow and white rim of the camera bubble; `pad` is the margin around the circle.
    static func bubbleFrame(diameter: CGFloat, pad: CGFloat) -> CIImage {
        let side = diameter + pad * 2
        return image(CGSize(width: side, height: side)) { ctx in
            let circle = CGRect(x: pad, y: pad, width: diameter, height: diameter)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -pad * 0.25), blur: pad * 0.6, color: CGColor(gray: 0, alpha: 0.6))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillEllipse(in: circle)
            ctx.restoreGState()
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(5)
            ctx.strokeEllipse(in: circle.insetBy(dx: -2.5, dy: -2.5))
        }
    }

    /// The system arrow, for recordings where the cursor is not part of the picture.
    static func cursor() -> (image: CIImage, hotSpot: CGPoint, points: CGSize)? {
        let cursor = NSCursor.arrow
        var rect = CGRect(origin: .zero, size: cursor.image.size)
        guard let cg = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return (CIImage(cgImage: cg, options: [.colorSpace: NSNull()]), cursor.hotSpot, cursor.image.size)
    }
}

// MARK: - Renderer

enum LaunchRenderer {
    private static func ease(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return 1 - pow(1 - t, 3)
    }

    static func render(screen: URL, track: CursorTrack, output: URL, options: LaunchOptions,
                       progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: screen)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecorderError(tr("The screen recording has no picture", "В записи экрана нет картинки"))
        }
        let duration = try await asset.load(.duration).seconds
        let range = try await videoTrack.load(.timeRange)
        let source = try await videoTrack.load(.naturalSize)
        guard duration > 0.2, source.width > 0, source.height > 0 else {
            throw RecorderError(tr("The recording is too short", "Запись слишком короткая"))
        }

        let canvas = options.canvas
        let fps = Double(options.fps)
        let frames = max(1, Int((duration * fps).rounded(.down)))
        let path = CameraPath.make(track: track, duration: duration, frames: frames, fps: fps, maxZoom: options.maxZoom)

        // Where the recording sits on the canvas. With captions it moves up to leave a band for them.
        let captions = (track.captions ?? []).sorted { $0.t < $1.t }
        let aspect = source.width / source.height
        var contentH = (canvas.height * (captions.isEmpty ? 0.86 : 0.73)).rounded()
        var contentW = (contentH * aspect).rounded()
        if contentW > canvas.width * 0.9 {
            contentW = (canvas.width * 0.9).rounded()
            contentH = (contentW / aspect).rounded()
        }
        let top = captions.isEmpty ? ((canvas.height - contentH) / 2).rounded() : (canvas.height * 0.05).rounded()
        let content = CGRect(x: ((canvas.width - contentW) / 2).rounded(), y: canvas.height - top - contentH,
                             width: contentW, height: contentH)
        let captionSprites = captions.map { Sprite.caption($0, canvas: canvas, band: content.minY) }
        let radius = (canvas.height * 0.02).rounded()
        let canvasRect = CGRect(origin: .zero, size: canvas)

        let plate = Sprite.plate(canvas: canvas, content: content, radius: radius)
        let mask = Sprite.mask(size: content.size, radius: radius)
        let border = Sprite.border(size: content.size, radius: radius)
        let ring = Sprite.ring()
        let cursorSprite = track.drawCursor ? Sprite.cursor() : nil
        let clear = CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: content.size))
        let black = CIImage(color: .black).cropped(to: canvasRect)

        let screenReader = try FrameReader(asset: asset, track: videoTrack, start: range.start.seconds)

        // Optional camera bubble.
        var cameraReader: FrameReader?
        var cameraSize = CGSize.zero
        let bubbleD = (canvas.height * 0.21).rounded()
        let bubblePad = (bubbleD * 0.22).rounded()
        var bubbleMask: CIImage?
        var bubbleFrame: CIImage?
        if let cameraURL = options.camera {
            let cameraAsset = AVURLAsset(url: cameraURL)
            if let cameraTrack = try? await cameraAsset.loadTracks(withMediaType: .video).first,
               let size = try? await cameraTrack.load(.naturalSize), size.width > 0,
               let start = try? await cameraTrack.load(.timeRange).start.seconds {
                cameraReader = try? FrameReader(asset: cameraAsset, track: cameraTrack, start: start)
                cameraSize = size
                bubbleMask = Sprite.circleMask(diameter: bubbleD)
                bubbleFrame = Sprite.bubbleFrame(diameter: bubbleD, pad: bubblePad)
            }
        }
        let bubbleOrigin = CGPoint(x: max(28, content.minX - bubbleD * 0.22), y: max(28, content.minY - bubbleD * 0.12))

        // Writer.
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvas.width),
            AVVideoHeightKey: Int(canvas.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: options.bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(options.fps),
                AVVideoMaxKeyFrameIntervalKey: Int(options.fps) * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(canvas.width),
            kCVPixelBufferHeightKey as String: Int(canvas.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(videoInput) else { throw RecorderError("Cannot add the video track") }
        writer.add(videoInput)

        // Sound: the replacement soundtrack, or whatever was recorded with the screen.
        let audioAsset: AVAsset = options.soundtrack ?? asset
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        let audioTracks = (try? await audioAsset.loadTracks(withMediaType: .audio)) ?? []
        if !audioTracks.isEmpty, let reader = try? AVAssetReader(asset: audioAsset) {
            let mix = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(mix), writer.canAdd(input) {
                reader.add(mix)
                writer.add(input)
                if reader.startReading() {
                    audioReader = reader
                    audioOutput = mix
                    audioInput = input
                }
            }
        }

        guard writer.startWriting() else { throw writer.error ?? RecorderError("Cannot start writing") }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
        ])
        var pendingAudio: CMSampleBuffer?
        var audioDone = audioInput == nil

        /// Appends the next piece of sound if it starts before `limit`. Returns false when there
        /// was nothing to append right now.
        func appendAudio(before limit: Double) -> Bool {
            guard !audioDone, let input = audioInput, let out = audioOutput else { return false }
            if pendingAudio == nil { pendingAudio = out.copyNextSampleBuffer() }
            guard let buffer = pendingAudio else {
                input.markAsFinished()
                audioDone = true
                return false
            }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            if time >= duration {
                input.markAsFinished()
                audioDone = true
                return false
            }
            guard time <= limit, input.isReadyForMoreMediaData else { return false }
            input.append(buffer)
            pendingAudio = nil
            return true
        }

        let scaleX = content.width, scaleY = content.height
        let debug = ProcessInfo.processInfo.environment["DEMOSUFLER_DEBUG"] != nil
        let cursorScale = content.width / max(1, options.displayPoints.width)

        for i in 0..<frames {
            try Task.checkCancellation()
            let t = Double(i) / fps
            while appendAudio(before: t + 0.5) {}

            // The writer interleaves picture and sound. When it will not take the next frame it is
            // waiting for sound, so give it sound, however far ahead that sound is (there may be
            // a silent gap). Waiting here without feeding sound would block forever.
            var waited = 0
            while !videoInput.isReadyForMoreMediaData {
                if writer.status != .writing { throw writer.error ?? RecorderError("The writer stopped") }
                if !appendAudio(before: .infinity) {
                    usleep(2_000)
                    waited += 1
                    if waited > 15_000 { throw RecorderError("The video writer stopped accepting frames") }
                }
            }
            guard let frame = screenReader.image(at: t) else { continue }

            // The part of the screen that is visible at this zoom level.
            let zoom = max(1, path.zoom[i])
            let w = 1 / zoom, h = 1 / zoom
            let cx = min(max(path.fx[i], w / 2), 1 - w / 2)
            let cy = min(max(path.fy[i], h / 2), 1 - h / 2)
            let extent = frame.extent
            if debug, i % Int(fps) == 0 {
                print(String(format: "t %.1f zoom %.3f focus %.3f %.3f centre %.3f %.3f extent %.0fx%.0f", t, zoom, path.fx[i], path.fy[i], cx, cy, extent.width, extent.height))
            }
            let crop = CGRect(x: extent.minX + (cx - w / 2) * extent.width,
                              y: extent.minY + (1 - cy - h / 2) * extent.height,
                              width: w * extent.width, height: h * extent.height)
            var picture = frame.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scaleY / crop.height,
                    kCIInputAspectRatioKey: (scaleX / crop.width) / (scaleY / crop.height),
                ])
                .cropped(to: CGRect(origin: .zero, size: content.size))

            /// Display position (0…1, top left origin) to a point inside the picture.
            func local(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: (x - (cx - w / 2)) / w * scaleX, y: (1 - (y - (cy - h / 2)) / h) * scaleY)
            }

            // Click ripples.
            for click in track.clicks where t >= click.t && t < click.t + 0.55 {
                let k = ease((t - click.t) / 0.55)
                let size = (22 + 74 * k) * cursorScale * zoom
                let s = size / Sprite.ringSize
                let p = local(click.x, click.y)
                let sprite = ring
                    .transformed(by: CGAffineTransform(scaleX: s, y: s))
                    .transformed(by: CGAffineTransform(translationX: p.x - size / 2, y: p.y - size / 2))
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: (1 - k) * 0.9)])
                picture = sprite.composited(over: picture)
            }

            // Drawn cursor (only when the recording itself has none).
            if let sprite = cursorSprite, let c = track.position(at: t) {
                var press = 1.0
                if let near = track.clicks.last(where: { $0.t <= t }), t - near.t < 0.18 {
                    press = 0.86 + 0.14 * ((t - near.t) / 0.18)
                }
                let s = cursorScale * zoom * 1.5 * press * (sprite.points.width / sprite.image.extent.width)
                let p = local(c.x, c.y)
                let hx = sprite.hotSpot.x / sprite.points.width * sprite.image.extent.width * s
                let hy = (1 - sprite.hotSpot.y / sprite.points.height) * sprite.image.extent.height * s
                let arrow = sprite.image
                    .transformed(by: CGAffineTransform(scaleX: s, y: s))
                    .transformed(by: CGAffineTransform(translationX: p.x - hx, y: p.y - hy))
                picture = arrow.composited(over: picture)
            }

            picture = picture.cropped(to: CGRect(origin: .zero, size: content.size))
            var layer = border.composited(over: picture).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: mask,
            ])

            // Opening move: the recording settles into place.
            let settle = 0.94 + 0.06 * ease(t / 0.7)
            layer = layer
                .transformed(by: CGAffineTransform(translationX: -content.width / 2, y: -content.height / 2))
                .transformed(by: CGAffineTransform(scaleX: settle, y: settle))
                .transformed(by: CGAffineTransform(translationX: content.midX, y: content.midY))
            var image = layer.composited(over: plate)

            // Captions: the new one rises in while the old one fades away.
            if let index = captions.lastIndex(where: { $0.t <= t }) {
                let age = t - captions[index].t
                let appear = ease(age / 0.35)
                if index > 0, age < 0.22 {
                    let leaving = captionSprites[index - 1].applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - age / 0.22)
                    ])
                    image = leaving.composited(over: image)
                }
                var arriving = captionSprites[index]
                    .transformed(by: CGAffineTransform(translationX: 0, y: -14 * (1 - appear)))
                if appear < 0.999 {
                    arriving = arriving.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: appear)
                    ])
                }
                image = arriving.composited(over: image)
            }

            // Camera bubble.
            if let reader = cameraReader, let maskImage = bubbleMask, let frameImage = bubbleFrame,
               let cam = reader.image(at: max(0, t - options.cameraOffset)) {
                let side = min(cameraSize.width, cameraSize.height)
                let square = CGRect(x: cam.extent.midX - side / 2, y: cam.extent.midY - side / 2, width: side, height: side)
                let s = bubbleD / side
                let face = cam.cropped(to: square)
                    .transformed(by: CGAffineTransform(translationX: -square.minX, y: -square.minY))
                    .transformed(by: CGAffineTransform(scaleX: s, y: s))
                    .applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: bubbleD, height: bubbleD)),
                        kCIInputMaskImageKey: maskImage,
                    ])
                    .transformed(by: CGAffineTransform(translationX: bubbleOrigin.x, y: bubbleOrigin.y))
                let rim = frameImage.transformed(by: CGAffineTransform(translationX: bubbleOrigin.x - bubblePad, y: bubbleOrigin.y - bubblePad))
                image = face.composited(over: rim.composited(over: image))
            }

            // Fade in at the start and out at the end.
            let fade = min(ease(t / 0.35), ease((duration - t) / 0.35))
            if fade < 0.999 {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: fade)
                ]).composited(over: black)
            }

            guard let pool = adaptor.pixelBufferPool else { throw RecorderError("No pixel buffer pool") }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let target = pixelBuffer else { throw RecorderError("No pixel buffer") }
            context.render(image, to: target, bounds: canvasRect, colorSpace: nil)
            if !adaptor.append(target, withPresentationTime: CMTime(value: Int64(i), timescale: options.fps)) {
                throw writer.error ?? RecorderError("Cannot append a frame")
            }
            if i % 15 == 0 { progress(Double(i) / Double(frames)) }
        }

        videoInput.markAsFinished()
        // The rest of the sound. Bounded, so a writer that stops listening cannot hang the app.
        var idle = 0
        while !audioDone, writer.status == .writing, idle < 5_000 {
            if appendAudio(before: .infinity) { idle = 0 } else if !audioDone { usleep(2_000); idle += 1 }
        }
        if !audioDone { audioInput?.markAsFinished() }
        audioReader?.cancelReading()
        screenReader.cancel()
        cameraReader?.cancel()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? RecorderError(tr("Could not finish the video", "Не удалось дописать видео"))
        }
        progress(1)
    }
}

// MARK: - Small media helpers (used by the tests and by the demo build)

enum MediaTools {
    /// One line per track: kind, size, frame rate, duration.
    static func describe(_ url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        var lines: [String] = []
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        lines.append(String(format: "duration %.2fs", duration))
        for track in (try? await asset.load(.tracks)) ?? [] {
            let size = (try? await track.load(.naturalSize)) ?? .zero
            let rate = (try? await track.load(.nominalFrameRate)) ?? 0
            let length = (try? await track.load(.timeRange).duration.seconds) ?? 0
            lines.append("\(track.mediaType.rawValue) \(Int(size.width))x\(Int(size.height)) \(String(format: "%.1f", rate))fps \(String(format: "%.2f", length))s")
        }
        return lines.joined(separator: "\n")
    }

    /// Saves the frame at `time` as a PNG.
    static func saveFrame(of url: URL, at time: Double, to png: URL, maxWidth: CGFloat = 1600) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw RecorderError("PNG failed") }
        try data.write(to: png)
    }

    /// Stretches of the video where the picture is pure black, as (start, end) in seconds.
    static func darkSpans(in url: URL) async throws -> [(Double, Double)] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError("Cannot read the video") }
        var spans: [(Double, Double)] = []
        var darkSince: Double?
        var last = 0.0
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            index += 1
            if index % 6 != 0 { continue }
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            last = time
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            var sum = 0, count = 0
            if let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) {
                let width = CVPixelBufferGetWidthOfPlane(pixels, 0), height = CVPixelBufferGetHeightOfPlane(pixels, 0)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for y in Swift.stride(from: 0, to: height, by: 24) {
                    for x in Swift.stride(from: 0, to: width, by: 24) {
                        sum += Int(bytes[y * stride + x])
                        count += 1
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            // Video range black is 16; anything this close to it is an empty frame.
            let dark = count > 0 && Double(sum) / Double(count) < 17.5
            if dark, darkSince == nil { darkSince = time }
            if !dark, let start = darkSince {
                if time - start > 0.15 { spans.append((start, time)) }
                darkSince = nil
            }
        }
        if let start = darkSince, last - start > 0.15 { spans.append((start, last)) }
        return spans
    }

    /// Lays sound clips on one timeline: each clip starts at its `at` second.
    static func soundtrack(clips: [(url: URL, at: Double)]) async throws -> AVAsset {
        let composition = AVMutableComposition()
        guard let lane = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecorderError("Cannot build the soundtrack")
        }
        for clip in clips.sorted(by: { $0.at < $1.at }) {
            let asset = AVURLAsset(url: clip.url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let length = try await asset.load(.duration)
            try lane.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source,
                                     at: CMTime(seconds: clip.at, preferredTimescale: 44_100))
        }
        return composition
    }
}
