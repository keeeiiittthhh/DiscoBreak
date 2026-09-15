import AppKit

/// Watches for the pointer entering the notch (or, on machines without one, a
/// top-centre hot zone of the same size).
///
/// Deliberately a poll, not an event tap: `NSEvent.mouseLocation` needs no
/// Accessibility permission, no entitlement, and no TCC prompt. At 20Hz the cost
/// is unmeasurable.
final class NotchDetector {

    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    private let settings: Settings
    private var timer: Timer?
    private var isInside = false
    private var exitPendingSince: Date?

    init(settings: Settings) {
        self.settings = settings
    }

    /// The display the show hangs from.
    ///
    /// Not `NSScreen.main` — that follows keyboard focus, so with an external
    /// display attached the notch zone would wander onto whichever screen was
    /// last clicked. The notch is physically on the built-in panel, always.
    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
            ?? NSScreen.screens.first
            ?? NSScreen.main
    }

    /// The rect the pointer must reach, in screen coordinates.
    static func hotZone(for screen: NSScreen, padding: CGFloat) -> CGRect {
        let frame = screen.frame
        let base: CGRect

        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0 {
            // Real notch: the gap between the two menu bar areas.
            let width = frame.width - left.width - right.width
            base = CGRect(x: frame.minX + left.width,
                          y: frame.maxY - screen.safeAreaInsets.top,
                          width: width,
                          height: screen.safeAreaInsets.top)
        } else {
            // No notch (external display, non-notched Mac): fake one.
            let width: CGFloat = 185, height: CGFloat = 32
            base = CGRect(x: frame.midX - width / 2,
                          y: frame.maxY - height,
                          width: width,
                          height: height)
        }

        return base.insetBy(dx: -padding, dy: -padding)
    }

    func start(screen: NSScreen) {
        stop()
        let zone = Self.hotZone(for: screen, padding: settings.hotZonePadding)
        NSLog("DiscoBreak hot zone: %@", NSStringFromRect(zone))

        let t = Timer(timeInterval: 1.0 / settings.pollHz, repeats: true) { [weak self] _ in
            self?.tick(zone: zone)
        }
        // .common so it keeps firing while menus are open or windows are being dragged.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick(zone: CGRect) {
        let inZone = zone.contains(NSEvent.mouseLocation)

        if inZone {
            exitPendingSince = nil
            if !isInside {
                isInside = true
                onEnter?()
            }
            return
        }

        guard isInside else { return }

        // Hysteresis: a quick sweep across the menu bar shouldn't retract the show.
        if let since = exitPendingSince {
            if Date().timeIntervalSince(since) >= settings.exitDelay {
                isInside = false
                exitPendingSince = nil
                onExit?()
            }
        } else {
            exitPendingSince = Date()
        }
    }
}
