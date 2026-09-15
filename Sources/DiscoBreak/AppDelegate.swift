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

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.make()
        item.button?.toolTip = "DiscoBreak — hover the notch"
        item.menu = buildMenu()
        statusItem = item
    }

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
    }
}
