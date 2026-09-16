import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = SettingsStore()
    private let windows = AppWindows()
    private var detector: NotchDetector!
    private var show: ShowController!
    private var statusItem: NSStatusItem?
    private var isPaused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)      // no Dock icon

        show = ShowController(settings: store.settings)
        installEditMenu()
        installStatusItem()
        restartDetector()

        store.onChange = { [weak self] new in
            self?.show.apply(new)
            self?.restartDetector()
        }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(environmentChanged),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(environmentChanged),
                       name: NSWorkspace.didWakeNotification, object: nil)
        // Screens, heat and battery all change what the show should cost. Each one
        // just drops the stages; the next hover rebuilds against the new reality.
        for name: Notification.Name in [
            NSApplication.didChangeScreenParametersNotification,
            ProcessInfo.thermalStateDidChangeNotification,
            .NSProcessInfoPowerStateDidChange
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged), name: name, object: nil)
        }

        windows.showOnboardingIfNeeded()
    }

    private func restartDetector() {
        detector?.stop()
        guard let screen = NotchDetector.notchScreen() else { return }
        detector = NotchDetector(settings: store.settings)
        detector.onEnter = { [weak self] in
            guard let self, !self.isPaused else { return }
            self.show.pointerEnteredNotch()
        }
        detector.onExit = { [weak self] in self?.show.pointerLeftNotch() }
        detector.start(screen: screen)
    }

    @objc private func environmentChanged() {
        show.hardReset()
        restartDetector()
    }

    // MARK: - Menu bar

    /// An app with no Dock icon gets no menu bar either — and macOS delivers
    /// Command-V by looking it up in the app's Edit menu. With no menu there was
    /// nothing to look it up in, so pasting a playlist link into Settings did
    /// nothing at all. This menu is never drawn anywhere; it exists so that the
    /// standard editing shortcuts resolve.
    ///
    /// Selectors are written out by name on purpose: they are dispatched down the
    /// responder chain to whatever text field is focused, so there is no concrete
    /// type here to take #selector of.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        func add(_ title: String, _ selector: String, _ key: String,
                 _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: Selector((selector)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.addItem(item)
        }
        add("Undo", "undo:", "z")
        add("Redo", "redo:", "Z", [.command, .shift])
        edit.addItem(.separator())
        add("Cut", "cut:", "x")
        add("Copy", "copy:", "c")
        add("Paste", "paste:", "v")
        add("Select All", "selectAll:", "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit

        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        item.behavior = []                     // never removable by dragging it off
        if let button = item.button {
            button.image = MenuBarIcon.make()
            button.imagePosition = .imageOnly
            button.toolTip = "DiscoBreak — hover the notch"
            // If the glyph ever fails to draw, fall back to text rather than to
            // an invisible item with no way to quit.
            if button.image == nil {
                button.title = "◍"
                button.imagePosition = .noImage
            }
        }
        item.menu = buildMenu()
        statusItem = item

        // Placement is asynchronous, so the frame is only trustworthy a beat later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.rescueFromNotch()
        }
    }

    /// On a Mac whose menu bar is already full, macOS hands a new status item the
    /// leftmost slot of the right-hand group — which on a notched display is
    /// *underneath the notch*. The item exists, reports itself visible, and cannot
    /// be seen or clicked. That is exactly how this app ended up with no way to quit.
    ///
    /// Detect it and claim a slot clear of the notch instead, the same way a
    /// ⌘-drag would. Done once: if the user later moves it, their choice stands.
    private func rescueFromNotch() {
        guard let item = statusItem,
              let frame = item.button?.window?.frame,
              let screen = NotchDetector.notchScreen(),
              screen.safeAreaInsets.top > 0 else { return }

        let notch = NotchDetector.hotZone(for: screen, padding: 0)
        let swallowed = frame.minX < notch.maxX + 8

        NSLog("DiscoBreak status item: frame=%@ notch=%@ swallowed=%d",
              NSStringFromRect(frame), NSStringFromRect(notch), swallowed ? 1 : 0)

        guard swallowed else { return }
        guard !UserDefaults.standard.bool(forKey: Self.rescuedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.rescuedKey)

        // Measured from the right edge of the screen. Far enough in to clear the
        // notch on every current MacBook, near enough that it stays in the
        // third-party group rather than fighting Control Center for space.
        UserDefaults.standard.set(340, forKey: "NSStatusItem Preferred Position Item-0")
        UserDefaults.standard.synchronize()

        // The position is only read when the status bar item is first created at
        // launch — removing and re-adding it here lands in the same bad slot. So
        // relaunch, once, on first run, before anyone has touched anything.
        relaunch()
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return }

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            guard error == nil, app != nil else {
                NSLog("DiscoBreak: relaunch failed (%@) — staying put",
                      error?.localizedDescription ?? "unknown")
                return
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static let rescuedKey = "DiscoBreak.statusItemRescued"

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let playing = NSMenuItem(title: "Hover the notch to start", action: nil, keyEquivalent: "")
        playing.tag = 1
        playing.isEnabled = false
        menu.addItem(playing)
        menu.addItem(.separator())

        add(menu, "Test Drop", #selector(testDrop), "t")
        let pause = add(menu, "Pause DiscoBreak", #selector(togglePause), "p")
        pause.tag = 2
        menu.addItem(.separator())

        // Two balls, one click apart. The checkmark shows which is hanging.
        let ball = NSMenuItem(title: "Ball", action: nil, keyEquivalent: "")
        let ballMenu = NSMenu()
        for style in BallStyle.allCases {
            let item = NSMenuItem(title: style.rawValue, action: #selector(chooseBall(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            ballMenu.addItem(item)
        }
        ball.submenu = ballMenu
        ball.tag = 3
        menu.addItem(ball)
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(openSettings), ",")
        menu.addItem(.separator())
        add(menu, "Quit DiscoBreak", #selector(quit), "q")
        return menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    @objc private func testDrop() {
        show.pointerEnteredNotch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.show.pointerLeftNotch()
        }
    }

    @objc private func togglePause() {
        isPaused.toggle()
        if isPaused { show.pointerLeftNotch() }
    }

    @objc private func chooseBall(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = BallStyle(rawValue: raw),
              style != store.settings.ballStyle else { return }
        store.settings.ballStyle = style      // saves, and rebuilds the show
    }

    @objc private func openSettings() {
        windows.showSettings(store: store) { [weak self] in self?.testDrop() }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    /// Refresh the live bits just before the menu draws, so nothing polls while closed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 1)?.title = show.nowPlaying.map { "♫  \($0)" } ?? "Hover the notch to start"
        menu.item(withTag: 2)?.title = isPaused ? "Resume DiscoBreak" : "Pause DiscoBreak"
        for item in menu.item(withTag: 3)?.submenu?.items ?? [] {
            item.state = item.representedObject as? String == store.settings.ballStyle.rawValue
                ? .on : .off
        }
    }
}
