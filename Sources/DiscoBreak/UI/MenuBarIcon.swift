import AppKit

/// A mirror-ball glyph drawn as a template image, so the menu bar tints it the way
/// it tints WiFi or screen mirroring — black on light menu bars, white on dark,
/// inverted when the menu is open. An emoji can do none of that, which is why the
/// MVP's 🪩 was effectively invisible.
enum MenuBarIcon {

    /// The shipped glyph, designed in Figma and exported as SVG. `NSImage` renders
    /// SVG as a vector rep, so it stays crisp at any menu bar size and on any display.
    static func make(size: CGFloat = 18) -> NSImage {
        if let image = artwork(size: size) { return image }
        NSLog("DiscoBreak: menubar-icon.svg missing — using the drawn fallback glyph")
        return drawn(size: size)
    }

    private static func artwork(size: CGFloat) -> NSImage? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/menubar-icon.svg")
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true          // macOS tints it: dark on light bars, light on dark
        return image
    }

    /// Kept so an unbundled `swift run`, or a bad copy of the app, still shows
    /// something clickable rather than an invisible status item.
    private static func drawn(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset: CGFloat = 1.5
            let circle = rect.insetBy(dx: inset, dy: inset)
            let r = circle.width / 2
            let c = CGPoint(x: circle.midX, y: circle.midY)

            NSColor.black.setStroke()

            let outline = NSBezierPath(ovalIn: circle)
            outline.lineWidth = 1.3
            outline.stroke()

            // Latitude lines, spaced so they read as a sphere rather than a grid.
            let lat = NSBezierPath()
            for f in [-0.55, 0.0, 0.55] as [CGFloat] {
                let y = c.y + r * f
                let halfChord = sqrt(max(0, r * r - (r * f) * (r * f)))
                lat.move(to: CGPoint(x: c.x - halfChord, y: y))
                lat.line(to: CGPoint(x: c.x + halfChord, y: y))
            }
            lat.lineWidth = 1.0
            lat.stroke()

            // Longitude lines as ellipses, narrowing toward the edges.
            let lon = NSBezierPath()
            for f in [0.42, 1.0] as [CGFloat] {
                let w = r * f
                lon.appendOval(in: NSRect(x: c.x - w, y: c.y - r, width: w * 2, height: r * 2))
            }
            lon.lineWidth = 1.0
            lon.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }
}
