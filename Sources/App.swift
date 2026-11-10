import AppKit
import SwiftUI

/// Окно суфлера. Это панель, которая не активирует приложение: только такие окна macOS
/// показывает поверх чужих полноэкранных программ и на всех рабочих столах.
final class PrompterPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    // Панель не делает приложение активным, поэтому меню «Правка» может не сработать.
    // Обрабатываем ⌘A ⌘Z ⌘X ⌘C ⌘V сами, по коду клавиши: так работает и в русской раскладке.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if event.type == .keyDown, flags == .command || flags == [.command, .shift] {
            let shift = flags.contains(.shift)
            let action: Selector?
            switch (event.keyCode, shift) {
            case (0, false): action = #selector(NSText.selectAll(_:))
            case (6, false): action = Selector(("undo:"))
            case (6, true): action = Selector(("redo:"))
            case (7, false): action = #selector(NSText.cut(_:))
            case (8, false): action = #selector(NSText.copy(_:))
            case (9, false): action = #selector(NSText.paste(_:))
            case (12, false): // ⌘Q: у приложения нет строки меню, выходим сами
                NSApp.terminate(nil)
                return true
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Приложение без иконки в Dock: только таким macOS надёжно разрешает держать окно
        // поверх чужих полноэкранных программ. Закрывается крестиком на панели или ⌘Q.
        app.setActivationPolicy(.accessory)
        app.run()
    }

    var panel: PrompterPanel!
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let screen = cameraScreen()
        let visible = screen.visibleFrame
        let size = NSSize(width: min(1060, visible.width - 40), height: 264)
        // По центру экрана и вплотную к верху: прямо под камерой.
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: visible.maxY - size.height - 2)

        panel = PrompterPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false
        // Выше обычных окон, закреплённых окон, Dock и строки меню.
        panel.level = .statusBar
        // На всех рабочих столах, поверх полноэкранных программ, не уезжает при свайпе и в Mission Control.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 820, height: 250)
        // Окно не попадает в запись и демонстрацию экрана.
        if ProcessInfo.processInfo.environment["DEMOSUFLER_VISIBLE"] == nil {
            panel.sharingType = .none
        }
        panel.contentView = NSHostingView(rootView: RootView().environmentObject(model))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        installShortcuts()
        model.updateDevices()
        model.checkForUpdate()
    }

    /// Экран с камерой: встроенный дисплей макбука, если он есть.
    private func cameraScreen() -> NSScreen {
        let builtIn = NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayIsBuiltin(id) != 0
        }
        return builtIn ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Клик по иконке в Dock возвращает окно, если оно потерялось.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.orderFrontRegardless()
        panel.makeKey()
        return true
    }

    private func installShortcuts() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] event in
            if self.model.editing { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
            if flags == .command && event.keyCode == 15 { // ⌘R
                self.model.toggleRecord()
                return nil
            }
            if !flags.intersection([.command, .control, .option]).isEmpty { return event }
            switch event.keyCode {
            case 49: // пробел
                self.model.scroller.toggle()
            case 126: // стрелка вверх
                self.model.speed = min(120, self.model.speed + 2)
            case 125: // стрелка вниз
                self.model.speed = max(5, self.model.speed - 2)
            default:
                return event
            }
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [unowned self] event in
            if self.model.editing { return event }
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            self.model.scroller.nudge(-event.scrollingDeltaY * step)
            return nil
        }
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Завершить demosufler", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Правка")
        editMenu.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.phase == .recording || model.phase == .saving {
            // Сначала дописываем файлы, потом выходим.
            model.stopRecording { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        model.camera.stop()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
