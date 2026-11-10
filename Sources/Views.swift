import AVFoundation
import AppKit
import SwiftUI

// MARK: - Whole panel

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            LeftColumn().frame(width: 204)
            separator
            center
            separator
            RightColumn().frame(width: 196)
        }
        .padding(14)
        .background(Color.black.opacity(1 - model.transparency))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    private var separator: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1).padding(.horizontal, 14)
    }

    private var center: some View {
        ZStack {
            if model.showSetup {
                SetupView()
            } else if model.editing {
                TextEditor(text: $model.script)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white)
                    .scrollContentBackground(.hidden)
            } else {
                PrompterView()
                if case .countdown(let n) = model.phase {
                    Color.black.opacity(0.7)
                    Text("\(n)")
                        .font(.system(size: 96, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .demoAnchor("text")
        .overlay(alignment: .bottom) {
            if model.phase == .idle { UpdateBar() }
        }
    }
}

// MARK: - Prompter

/// Draws only the visible lines of the script and redraws on every scroll step.
/// This is plain AppKit on purpose: scrolling never goes through SwiftUI layout.
final class PrompterNSView: NSView {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer()
    private var signature = ""
    private var lastHeight: CGFloat = -1

    var onHeight: ((CGFloat) -> Void)?
    var offset: CGFloat = 0 {
        didSet { if offset != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(paragraphs: [Paragraph], fontSize: CGFloat, glassy: Bool) {
        let key = "\(fontSize)|\(glassy)|" + paragraphs.map { ($0.isCue ? "#" : "") + $0.text }.joined(separator: "\n")
        guard key != signature else { return }
        signature = key

        let text = NSMutableAttributedString()
        // On a see-through background the text needs a shadow to stay readable over bright windows.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.95)
        shadow.shadowBlurRadius = 3
        for (index, paragraph) in paragraphs.enumerated() {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = fontSize * 0.16
            style.paragraphSpacing = fontSize * 0.6
            var attributes: [NSAttributedString.Key: Any] = [
                .font: paragraph.isCue
                    ? NSFont.systemFont(ofSize: fontSize * 0.6, weight: .regular)
                    : NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(paragraph.isCue ? 0.45 : 1),
                .paragraphStyle: style,
            ]
            if glassy { attributes[.shadow] = shadow }
            let line = paragraph.text + (index == paragraphs.count - 1 ? "" : "\n")
            text.append(NSAttributedString(string: line, attributes: attributes))
        }
        storage.setAttributedString(text)
        relayout()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        // Not on screen yet: a layout at a made-up width would report a made-up height.
        guard bounds.width > 40 else { return }
        let width = bounds.width
        if container.size.width != width {
            container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
        manager.ensureLayout(for: container)
        let height = ceil(manager.usedRect(for: container).height)
        if height != lastHeight {
            lastHeight = height
            onHeight?(height)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let visible = CGRect(x: 0, y: offset, width: bounds.width, height: bounds.height)
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
        manager.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: 0, y: -offset))

        // The top stays bright (it is closest to the camera), the bottom fades out.
        context.saveGState()
        context.setBlendMode(.destinationIn)
        let colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0.22)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 0.45, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: bounds.height),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.restoreGState()
    }
}

struct PrompterView: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeNSView(context: Context) -> PrompterNSView {
        let view = PrompterNSView()
        let model = self.model
        let scroller = model.scroller
        scroller.onChange = { [weak view, weak scroller] in
            view?.offset = scroller?.offset ?? 0
        }
        view.onHeight = { height in
            DispatchQueue.main.async {
                if model.contentHeight != height { model.contentHeight = height }
            }
        }
        return view
    }

    func updateNSView(_ view: PrompterNSView, context: Context) {
        view.update(paragraphs: model.paragraphs, fontSize: CGFloat(model.fontSize), glassy: model.transparency > 0.05)
        view.offset = model.scroller.offset
    }
}

// MARK: - Permissions setup

struct SetupView: View {
    @EnvironmentObject var model: AppModel

    private var cameraNeeded: Bool { model.cameraAccess != .granted }
    private var micNeeded: Bool { model.micAccess != .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.onboarded
                         ? tr("macOS is asking for permissions again", "macOS просит разрешения заново")
                         : tr("Three permissions and you can record", "Три разрешения, и можно записывать"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white)
                    Text(tr("Recordings stay on this Mac, in Movies/demosufler",
                            "Записи остаются на этом Mac, в папке Фильмы/demosufler"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                Spacer(minLength: 8)
                LangSwitch()
                SetupButton(title: model.missingAccess ? tr("Later", "Позже") : tr("Start", "Начать"),
                            primary: !model.missingAccess) {
                    model.closeSetup()
                }
                .demoAnchor("setup.start")
            }
            .padding(.bottom, 2)

            SetupRow(icon: "video.fill", title: tr("Camera", "Камера"),
                     detail: model.cameraAccess == .denied
                        ? tr("Blocked. Turn demosufler on in Settings", "Запрещено. Включи demosufler в настройках")
                        : tr("To record you", "Чтобы записывать тебя"),
                     granted: model.cameraAccess == .granted) {
                SetupButton(title: model.cameraAccess == .denied ? tr("Open Settings", "Открыть настройки") : tr("Allow", "Разрешить"),
                            primary: true) {
                    model.askCamera()
                }
                .demoAnchor("setup.camera")
            }
            SetupRow(icon: "mic.fill", title: tr("Microphone", "Микрофон"),
                     detail: model.micAccess == .denied
                        ? tr("Blocked. Turn demosufler on in Settings", "Запрещено. Включи demosufler в настройках")
                        : tr("On only while recording", "Включается только на время записи"),
                     granted: model.micAccess == .granted) {
                SetupButton(title: model.micAccess == .denied ? tr("Open Settings", "Открыть настройки") : tr("Allow", "Разрешить"),
                            primary: !cameraNeeded) {
                    model.askMic()
                }
                .demoAnchor("setup.mic")
            }
            SetupRow(icon: "display", title: tr("Screen recording", "Запись экрана"),
                     detail: screenDetail, granted: model.screenAccess) {
                if model.screenAsked {
                    SetupButton(title: tr("Settings", "Настройки"), primary: false) { model.askScreen() }
                    SetupButton(title: tr("Restart", "Перезапустить"), primary: true) { model.relaunch() }
                } else {
                    SetupButton(title: tr("Open Settings", "Открыть настройки"), primary: !cameraNeeded && !micNeeded) {
                        model.askScreen()
                    }
                    .demoAnchor("setup.screen")
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var screenDetail: String {
        if model.screenAccess { return tr("The prompter itself is never in the recording", "Панель суфлера в запись не попадает") }
        if model.screenAsked {
            return tr("Turn demosufler on in the list, then press Restart",
                      "Включи demosufler в списке, потом нажми «Перезапустить»")
        }
        return tr("Only for the Screen, Both and Launch modes", "Нужно только для режимов «Экран», «Оба» и «Ролик»")
    }
}

struct SetupRow<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(granted ? 0.5 : 0.9))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.09)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(granted ? 0.6 : 1))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if granted {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(tr("Allowed", "Разрешено"))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
                .padding(.trailing, 4)
            } else {
                trailing()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

struct SetupButton: View {
    let title: String
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(primary ? Color.black : Color.white.opacity(0.9))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(primary ? Color.white : Color.white.opacity(0.12))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Interface language: English or Russian.
struct LangSwitch: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Lang.allCases, id: \.self) { lang in
                Button {
                    model.lang = lang
                } label: {
                    Text(lang.rawValue.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(model.lang == lang ? Color.black : Color.white.opacity(0.6))
                        .frame(width: 24, height: 17)
                        .background(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(model.lang == lang ? Color.white : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .demoAnchor("lang.\(lang.rawValue)")
            }
        }
        .padding(1.5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.09)))
        .help(tr("Interface language", "Язык интерфейса"))
    }
}

// MARK: - Update bar

struct UpdateBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.update {
        case .none:
            EmptyView()
        case .available(let info):
            bar {
                Text(tr("Version \(info.version) is out", "Вышла версия \(info.version)"))
                Spacer(minLength: 8)
                action(Updater.canSelfUpdate || model.demo ? tr("Update", "Обновить") : tr("Download", "Скачать")) {
                    model.installUpdate()
                }
                .demoAnchor("update")
                .help(Updater.canSelfUpdate
                      ? tr("Downloads the new version and restarts demosufler", "Скачает новую версию и перезапустит demosufler")
                      : tr("Move demosufler to Applications and updates will install themselves",
                           "Перенеси demosufler в «Программы», и обновления будут ставиться сами"))
                close
            }
        case .installing(let info):
            bar {
                ProgressView().controlSize(.small)
                Text(tr("Installing version \(info.version)…", "Ставлю версию \(info.version)…"))
                Spacer(minLength: 8)
            }
        case .failed(_, let message):
            bar {
                Text(tr("Update failed: ", "Не обновилось: ") + message).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                action(tr("Download manually", "Скачать вручную")) { model.openDownloadPage() }
                close
            }
        }
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.black)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
            .environment(\.colorScheme, .light)
            .padding(.bottom, 2)
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var close: some View {
        Button { model.update = .none } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.55))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Later", "Позже"))
    }
}

// MARK: - Left column: preview and mode

struct LeftColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06))
                if model.demo && model.usesCamera {
                    DemoFace()
                } else if model.usesCamera && model.cameraReady, let layer = model.camera.previewLayer {
                    CameraPreview(layer: layer)
                } else {
                    Image(systemName: model.usesCamera ? "video.slash" : "display")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            ModePicker()
            statusLine
            if model.mode == .launch {
                Button { model.launchBubble.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.launchBubble ? "checkmark.circle.fill" : "circle")
                        Text(tr("Camera bubble in the video", "Кружок с камерой в ролике"))
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.phase != .idle)
                .demoAnchor("bubble")
            }
            Spacer(minLength: 0)
            HStack {
                Text("demosufler \(Updater.currentVersion)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.28))
                Spacer(minLength: 4)
                LangSwitch()
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if model.status.isEmpty {
            statusText(model.mode.hint, opacity: 0.45)
        } else if model.statusAction != nil {
            Button { model.runStatusAction() } label: {
                statusText(model.status, opacity: 0.9).underline().contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            statusText(model.status, opacity: 0.85)
        }
    }

    private func statusText(_ text: String, opacity: Double) -> Text {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundColor(Color.white.opacity(opacity))
    }
}

struct ModePicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button {
                    model.mode = m
                } label: {
                    Text(m.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(model.mode == m ? Color.black : Color.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(model.mode == m ? Color.white : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .demoAnchor("mode.\(m.rawValue)")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.09)))
        .disabled(model.phase != .idle)
        .opacity(model.phase == .idle ? 1 : 0.5)
    }
}

// MARK: - Right column: speed, size, transparency, record

struct RightColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(title: tr("SPEED", "СКОРОСТЬ"), trailing: model.estimate, value: $model.speed, range: 5...120)
                .demoAnchor("speed")
            LabeledSlider(title: tr("SIZE", "РАЗМЕР"), trailing: "\(Int(model.fontSize))", value: $model.fontSize, range: 16...52)
                .demoAnchor("size")
            LabeledSlider(title: tr("TRANSPARENCY", "ПРОЗРАЧНОСТЬ"), trailing: "\(Int((model.transparency * 100).rounded()))%",
                          value: $model.transparency, range: 0...0.85)
                .demoAnchor("transparency")

            HStack(spacing: 5) {
                PlayButton(scroller: model.scroller)
                    .demoAnchor("play")
                IconButton(icon: "backward.end.fill", help: tr("Back to the top", "В начало текста")) {
                    model.scroller.pause()
                    model.scroller.reset()
                }
                IconButton(icon: model.editing ? "checkmark" : "pencil",
                           help: model.editing ? tr("Done", "Готово") : tr("Edit the text", "Изменить текст")) {
                    model.editing.toggle()
                }
                .disabled(model.phase != .idle || model.showSetup)
                .demoAnchor("edit")
                IconButton(icon: "folder", help: tr("Recordings folder", "Папка с записями")) { model.openFolder() }
                IconButton(icon: "xmark", help: tr("Quit demosufler", "Закрыть demosufler")) { NSApp.terminate(nil) }
            }

            Spacer(minLength: 0)
            RecordButton()
                .demoAnchor("record")
        }
    }
}

struct LabeledSlider: View {
    let title: String
    let trailing: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).tracking(1.2)
                Spacer()
                Text(trailing).monospacedDigit()
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.5))
            Slider(value: $value, in: range)
                .controlSize(.small)
                .tint(.white)
        }
    }
}

struct IconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.09)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct PlayButton: View {
    @ObservedObject var scroller: Scroller

    var body: some View {
        IconButton(icon: scroller.playing ? "pause.fill" : "play.fill", help: tr("Scroll (Space)", "Прокрутка (пробел)")) {
            scroller.toggle()
        }
    }
}

struct RecordButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let idle = model.phase == .idle
        Button {
            model.toggleRecord()
        } label: {
            HStack(spacing: 8) {
                switch model.phase {
                case .idle:
                    Circle().fill(Color.black).frame(width: 9, height: 9)
                    Text(tr("Record", "Запись"))
                case .countdown(let n):
                    Text(tr("Cancel · \(n)", "Отмена · \(n)"))
                case .recording:
                    RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 9, height: 9)
                    Text(tr("Stop · ", "Стоп · ") + AppModel.clock(model.elapsed)).monospacedDigit()
                case .saving:
                    Text(tr("Saving…", "Сохраняю…"))
                case .rendering(let percent):
                    Text(tr("Building video · \(percent)%", "Собираю ролик · \(percent)%")).monospacedDigit()
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(idle ? Color.black : Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(idle ? Color.white : Color.white.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(idle ? 0 : 0.5), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .help(tr("Record (⌘R)", "Запись (⌘R)"))
    }

    private var isBusy: Bool {
        switch model.phase {
        case .saving, .rendering: return true
        default: return false
        }
    }
}

// MARK: - Camera preview

struct CameraPreview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> PreviewView { PreviewView(preview: layer) }

    func updateNSView(_ view: PreviewView, context: Context) { view.adopt() }
}

/// Shows the camera's preview layer. The layer belongs to the camera and outlives this view,
/// so SwiftUI can create and drop the view freely without ever touching the capture session.
final class PreviewView: NSView {
    private let preview: AVCaptureVideoPreviewLayer

    init(preview: AVCaptureVideoPreviewLayer) {
        self.preview = preview
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        adopt()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Moves the shared layer into this view (it may still sit in a view that is going away).
    func adopt() {
        guard preview.superlayer !== layer else { return }
        preview.removeFromSuperlayer()
        layer?.addSublayer(preview)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        CATransaction.commit()
    }
}
