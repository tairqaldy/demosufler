import AVFoundation
import AppKit
import SwiftUI

// MARK: - Окно целиком

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            LeftColumn().frame(width: 196)
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
            if model.editing {
                TextEditor(text: $model.script)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white)
                    .scrollContentBackground(.hidden)
            } else {
                PrompterView(scroller: model.scroller)
                if case .countdown(let n) = model.phase {
                    Color.black.opacity(0.7)
                    Text("\(n)")
                        .font(.system(size: 96, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if model.phase == .idle { UpdateBar() }
        }
    }
}

// MARK: - Суфлер

struct PrompterView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var scroller: Scroller

    var body: some View {
        let size = CGFloat(model.fontSize)
        // На прозрачном фоне тексту нужна тень, иначе на светлом окне его не видно.
        let glassy = model.transparency > 0.05
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: size * 0.6) {
                ForEach(model.paragraphs) { p in
                    Text(p.text)
                        .font(.system(size: p.isCue ? size * 0.6 : size, weight: p.isCue ? .regular : .medium))
                        .foregroundStyle(Color.white.opacity(p.isCue ? 0.45 : 1))
                        .lineSpacing(size * 0.16)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                model.contentHeight = height
            }
            .shadow(color: Color.black.opacity(glassy ? 0.95 : 0), radius: 2.5)
            .offset(y: -scroller.offset)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .clipped()
        // Верх яркий (он ближе всего к камере), низ уходит в темноту.
        .mask(LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.45),
                .init(color: .black.opacity(0.22), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        ))
    }
}

// MARK: - Полоска обновления

struct UpdateBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.update {
        case .none:
            EmptyView()
        case .available(let info):
            bar {
                Text("Вышла версия \(info.version)")
                Spacer(minLength: 8)
                action(Updater.canSelfUpdate ? "Обновить" : "Скачать") { model.installUpdate() }
                    .help(Updater.canSelfUpdate
                          ? "Скачает новую версию и перезапустит demosufler"
                          : "Перенеси demosufler в «Программы», и обновления будут ставиться сами")
                close
            }
        case .installing(let info):
            bar {
                ProgressView().controlSize(.small)
                Text("Ставлю версию \(info.version)…")
                Spacer(minLength: 8)
            }
        case .failed(_, let message):
            bar {
                Text("Не обновилось: \(message)").lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                action("Скачать вручную") { model.openDownloadPage() }
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
        .help("Позже")
    }
}

// MARK: - Левая колонка: превью и режим

struct LeftColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06))
                if model.mode.usesCamera && model.cameraReady {
                    CameraPreview(session: model.camera.session)
                } else {
                    Image(systemName: model.mode.usesCamera ? "video.slash" : "display")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            ModePicker()
            statusLine
            Spacer(minLength: 0)
            Text("demosufler \(Updater.currentVersion)")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.28))
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
        HStack(spacing: 2) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button {
                    model.mode = m
                } label: {
                    Text(m.title)
                        .font(.system(size: 11, weight: .medium))
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
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.09)))
        .disabled(model.phase != .idle)
        .opacity(model.phase == .idle ? 1 : 0.5)
    }
}

// MARK: - Правая колонка: скорость, размер, прозрачность, запись

struct RightColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(title: "СКОРОСТЬ", trailing: model.estimate, value: $model.speed, range: 5...120)
            LabeledSlider(title: "РАЗМЕР", trailing: "\(Int(model.fontSize))", value: $model.fontSize, range: 16...52)
            LabeledSlider(title: "ПРОЗРАЧНОСТЬ", trailing: "\(Int((model.transparency * 100).rounded()))%",
                          value: $model.transparency, range: 0...0.85)

            HStack(spacing: 5) {
                PlayButton(scroller: model.scroller)
                IconButton(icon: "backward.end.fill", help: "В начало текста") {
                    model.scroller.pause()
                    model.scroller.reset()
                }
                IconButton(icon: model.editing ? "checkmark" : "pencil",
                           help: model.editing ? "Готово" : "Изменить текст") {
                    model.editing.toggle()
                }
                .disabled(model.phase != .idle)
                IconButton(icon: "folder", help: "Папка с записями") { model.openFolder() }
                IconButton(icon: "xmark", help: "Закрыть demosufler") { NSApp.terminate(nil) }
            }

            Spacer(minLength: 0)
            RecordButton()
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
        IconButton(icon: scroller.playing ? "pause.fill" : "play.fill", help: "Прокрутка (пробел)") {
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
                    Text("Запись")
                case .countdown(let n):
                    Text("Отмена · \(n)")
                case .recording:
                    RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 9, height: 9)
                    Text("Стоп · " + AppModel.clock(model.elapsed)).monospacedDigit()
                case .saving:
                    Text("Сохраняю…")
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
        .disabled(model.phase == .saving)
        .help("Запись (⌘R)")
    }
}

// MARK: - Превью камеры

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateNSView(_ nsView: PreviewView, context: Context) {}
}

final class PreviewView: NSView {
    private let preview: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
        // Превью зеркальное, как в зеркале; в файл пишется обычная картинка.
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        CATransaction.commit()
    }
}
