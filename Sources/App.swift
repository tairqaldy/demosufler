import AppKit
import SwiftUI

/// The prompter window. It is a panel that does not activate the app: only such windows are
/// shown by macOS above other apps' full screen windows and on every desktop.
final class PrompterPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    // The panel does not make the app active, so the Edit menu may not respond.
    // ⌘A ⌘Z ⌘X ⌘C ⌘V are handled here by key code, which also works in a Russian layout.
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
            case (12, false): // ⌘Q
                NSApp.terminate(nil)
                return true
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Quits the app if its interface stops responding, so a stuck panel can never stay on screen.
/// (The app has no Dock icon, so it does not appear in the Force Quit window either.)
final class Watchdog {
    private let lock = NSLock()
    private var lastAnswer = ProcessInfo.processInfo.systemUptime

    func start(limit: TimeInterval = 10) {
        let thread = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                DispatchQueue.main.async {
                    self.lock.lock()
                    self.lastAnswer = ProcessInfo.processInfo.systemUptime
                    self.lock.unlock()
                }
                lock.lock()
                let silence = ProcessInfo.processInfo.systemUptime - lastAnswer
                lock.unlock()
                if silence > limit {
                    FileHandle.standardError.write(Data("demosufler: the interface stopped responding, quitting\n".utf8))
                    exit(70)
                }
            }
        }
        thread.name = "demosufler.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let command = arguments.first, Tools.commands.contains(command) {
            // Command line helpers used for tests and for building the product video.
            _ = NSApplication.shared
            Task {
                let code = await Tools.run(arguments)
                exit(code)
            }
            while true { RunLoop.main.run(until: .distantFuture) }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // No Dock icon: this is what lets the panel stay above other apps' full screen windows.
        // It quits from the × on the panel, from its menu bar icon, or with ⌘Q.
        app.setActivationPolicy(.accessory)
        app.run()
    }

    var panel: PrompterPanel!
    let model = AppModel()
    private let watchdog = Watchdog()
    private var leaving = false
    private var readyToLeave = false
    private var statusItem: NSStatusItem?
    private var backdrop: NSWindow?
    private var director: DemoDirector?
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let screen = cameraScreen()
        let visible = screen.visibleFrame
        let size = NSSize(width: min(1068, visible.width - 40), height: 276)
        // Centred and right at the top: directly under the camera.
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
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 840, height: 262)
        panel.contentView = NSHostingView(rootView: RootView().environmentObject(model))

        if Demo.active {
            startDemo(on: screen)
            return
        }

        // Above normal windows, pinned windows, the Dock and the menu bar.
        panel.level = .statusBar
        // On every desktop, above full screen apps, staying put during swipes and Mission Control.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The panel never shows up in screen recordings or screen sharing.
        if ProcessInfo.processInfo.environment["DEMOSUFLER_VISIBLE"] == nil {
            panel.sharingType = .none
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        installShortcuts()
        installStatusItem()
        watchdog.start()
        // Test hook: freeze the interface on purpose to prove that the watchdog quits the app.
        if ProcessInfo.processInfo.environment["DEMOSUFLER_TEST_HANG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { while true { sleep(1) } }
        }
        model.start()
        model.checkForUpdate()

        // Test hook: DEMOSUFLER_TEST_QUIT=<seconds> records for that long (0 = do not record)
        // and then quits the normal way, so that the time a quit takes can be measured.
        if let value = ProcessInfo.processInfo.environment["DEMOSUFLER_TEST_QUIT"], let seconds = Double(value) {
            if seconds > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.toggleRecord() } }
            let trace = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.note("phase \(self.model.phase) setup \(self.model.showSetup) status '\(self.model.status)' update \(self.model.update)")
            }
            RunLoop.main.add(trace, forMode: .common)
            DispatchQueue.main.asyncAfter(deadline: .now() + (seconds > 0 ? 4.6 + seconds : 2)) {
                self.note("terminate")
                NSApp.terminate(nil)
            }
        }
    }

    /// The screen with the camera: the MacBook's own display when there is one.
    private func cameraScreen() -> NSScreen {
        let builtIn = NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayIsBuiltin(id) != 0
        }
        return builtIn ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    // MARK: Menu bar icon

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "demosufler")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        let toggle = panel.isVisible ? tr("Hide the prompter", "Скрыть суфлер") : tr("Show the prompter", "Показать суфлер")
        menu.addItem(withTitle: toggle, action: #selector(togglePanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Recordings folder", "Папка с записями"), action: #selector(openFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Quit demosufler", "Завершить demosufler"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { showPanel() }
    }

    @objc private func openFolder() { model.openFolder() }

    private func showPanel() {
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    // MARK: Keyboard and scrolling

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
            case 49: // space
                self.model.scroller.toggle()
            case 126: // up arrow
                self.model.speed = min(120, self.model.speed + 2)
            case 125: // down arrow
                self.model.speed = max(5, self.model.speed - 2)
            default:
                return event
            }
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [unowned self] event in
            if self.model.editing || self.model.showSetup { return event }
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            self.model.scroller.nudge(-event.scrollingDeltaY * step)
            return nil
        }
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("Quit demosufler", "Завершить demosufler"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: tr("Edit", "Правка"))
        editMenu.addItem(withTitle: tr("Undo", "Отменить"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: tr("Cut", "Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: tr("Copy", "Копировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: tr("Paste", "Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: tr("Select All", "Выбрать всё"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToLeave || !(model.phase == .recording || model.phase == .saving) {
            leaveNow()
            return .terminateNow
        }
        // A recording is being written: finish the files first, then quit.
        //
        // This deliberately does not answer "terminate later". While AppKit waits for that
        // answer it runs the main thread in a special mode in which queued work (and Swift
        // tasks on the main actor) is not carried out, so the save could never complete and the
        // quit hung. Instead the quit is cancelled, the save runs normally, and the app quits by
        // itself as soon as it is done, or after a few seconds at the latest.
        if !leaving {
            leaving = true
            note("saving")
            let finish = { [self] in
                if readyToLeave { return }
                readyToLeave = true
                NSApp.terminate(nil)
            }
            model.stopRecording(then: finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: finish)
        }
        return .terminateCancel
    }

    /// The panel disappears at once, and the process is gone within half a second whatever the
    /// camera or AppKit still want to tidy up. Nothing is being written at this point.
    private func leaveNow() {
        note("quit")
        panel.orderOut(nil)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        UserDefaults.standard.synchronize()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { _exit(0) }
    }

    /// Test hook: timestamps on standard output when DEMOSUFLER_TEST_QUIT is set.
    private func note(_ what: String) {
        guard ProcessInfo.processInfo.environment["DEMOSUFLER_TEST_QUIT"] != nil else { return }
        print(String(format: "%@ %.3f", what, ProcessInfo.processInfo.systemUptime))
        fflush(stdout)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Scripted demo

    private func startDemo(on screen: NSScreen) {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "demo film")
        // Hidden behind the desktop picture, so the person at the Mac is not disturbed.
        let level: NSWindow.Level = Demo.visible
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)

        let stage = DemoStage()
        let back = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        back.isOpaque = true
        back.backgroundColor = .black
        back.isReleasedWhenClosed = false
        back.ignoresMouseEvents = true
        // One level under the prompter, so the prompter is always drawn on top of it.
        back.level = NSWindow.Level(rawValue: level.rawValue - 1)
        back.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let panelFrame = CGRect(x: panel.frame.minX - screen.frame.minX, y: screen.frame.maxY - panel.frame.maxY,
                                width: panel.frame.width, height: panel.frame.height)
        back.contentView = NSHostingView(rootView: BackdropView(stage: stage, panelFrame: panelFrame))
        back.setFrame(screen.frame, display: true)
        back.orderFrontRegardless()
        backdrop = back

        panel.level = level
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.orderFrontRegardless()
        panel.order(.above, relativeTo: back.windowNumber)

        model.start()
        let director = DemoDirector(model: model, panel: panel, backdrop: back, stage: stage)
        self.director = director
        director.run()
    }
}
