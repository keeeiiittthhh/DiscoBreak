import AppKit

/// A full-screen, transparent, click-through window that floats above every other
/// window on the system — including apps in fullscreen mode.
///
/// Everything the disco show draws lives in `hostLayer`.
final class OverlayWindow: NSWindow {

    let hostLayer = CALayer()

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Transparent and invisible to the window manager.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true          // clicks pass straight through to apps below
        isReleasedWhenClosed = false
        displaysWhenScreenProfileChanges = true

        // Above everything, on every Space, including other apps' fullscreen Spaces.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let view = NSView(frame: screen.frame)
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.isGeometryFlipped = false   // AppKit coords: origin bottom-left
        view.layer?.addSublayer(hostLayer)
        hostLayer.frame = view.bounds
        contentView = view

        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
