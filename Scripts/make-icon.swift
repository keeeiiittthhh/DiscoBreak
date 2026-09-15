import AppKit
import Foundation

// Draws the DiscoBreak app icon and emits a full .iconset, then leaves the
// iconutil call to the shell. Same visual language as the show: dark room,
// mirror ball, coloured spots thrown onto the back wall.

func drawIcon(size S: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: S, height: S))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
    ctx.setAllowsAntialiasing(true)

    // --- squircle-ish plate, macOS icon margins -------------------------
    let inset = S * 0.055
    let plate = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let radius = plate.width * 0.225
    let clip = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
    clip.addClip()

    // Dark club wall
    let bg = NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.06, blue: 0.20, alpha: 1),
        NSColor(calibratedRed: 0.03, green: 0.02, blue: 0.07, alpha: 1)
    ])!
    bg.draw(in: plate, angle: -90)

    let centre = CGPoint(x: plate.midX, y: plate.midY + plate.height * 0.04)
    let ballR = plate.width * 0.235

    // --- thrown light spots on the wall ---------------------------------
    let palette = [
        NSColor(calibratedRed: 0.40, green: 0.95, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.35, blue: 0.85, alpha: 1),
        NSColor(calibratedRed: 0.65, green: 0.45, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 1.00, blue: 1.00, alpha: 1)
    ]
    ctx.saveGState()
    ctx.setBlendMode(.plusLighter)
    var seed: UInt64 = 0x51CE
    func rnd() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((seed >> 33) % 10_000) / 10_000
    }
    for i in 0..<26 {
        let ang = rnd() * .pi * 2
        let dist = (0.38 + rnd() * 0.72) * plate.width * 0.5
        let p = CGPoint(x: centre.x + cos(ang) * dist, y: centre.y + sin(ang) * dist * 0.85)
        let minor = plate.width * (0.020 + rnd() * 0.022)
        let major = minor * (1.2 + rnd() * 1.9)
        let colour = palette[i % palette.count]

        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: ang + (rnd() - 0.5) * 0.9)
        let rect = CGRect(x: -major, y: -minor, width: major * 2, height: minor * 2)
        let g = NSGradient(colors: [colour.withAlphaComponent(0.85), colour.withAlphaComponent(0)])!
        NSBezierPath(ovalIn: rect).addClip()
        g.draw(in: rect, relativeCenterPosition: .zero)
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // --- chain -----------------------------------------------------------
    let chain = NSBezierPath()
    chain.move(to: CGPoint(x: centre.x, y: plate.maxY))
    chain.line(to: CGPoint(x: centre.x, y: centre.y))
    chain.lineWidth = max(1, S * 0.018)
    NSColor(calibratedWhite: 0.78, alpha: 0.9).setStroke()
    chain.stroke()

    // --- the ball --------------------------------------------------------
    let ballRect = CGRect(x: centre.x - ballR, y: centre.y - ballR, width: ballR * 2, height: ballR * 2)
    ctx.saveGState()
    NSBezierPath(ovalIn: ballRect).addClip()

    NSGradient(colors: [
        NSColor(calibratedRed: 0.78, green: 0.83, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.34, alpha: 1)
    ])!.draw(in: ballRect, relativeCenterPosition: CGPoint(x: -0.35, y: 0.4))

    // facet grid: latitude chords + longitude ellipses
    NSColor(calibratedWhite: 0.05, alpha: 0.55).setStroke()
    let grid = NSBezierPath()
    grid.lineWidth = max(0.6, S * 0.006)
    let rows = 7
    for i in 1..<rows {
        let f = CGFloat(i) / CGFloat(rows)
        let y = ballRect.minY + ballRect.height * f
        let half = sqrt(max(0, ballR * ballR - pow(y - centre.y, 2)))
        grid.move(to: CGPoint(x: centre.x - half, y: y))
        grid.line(to: CGPoint(x: centre.x + half, y: y))
    }
    for i in 1..<rows {
        let f = CGFloat(i) / CGFloat(rows)
        let w = abs(cos(f * .pi)) * ballR
        grid.appendOval(in: CGRect(x: centre.x - w, y: ballRect.minY,
                                   width: w * 2, height: ballRect.height))
    }
    grid.stroke()

    // sparkle on a few facets, plus the highlight
    ctx.setBlendMode(.plusLighter)
    for _ in 0..<9 {
        let ang = rnd() * .pi * 2
        let d = rnd() * ballR * 0.8
        let p = CGPoint(x: centre.x + cos(ang) * d, y: centre.y + sin(ang) * d)
        let r = ballR * (0.06 + rnd() * 0.07)
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        NSBezierPath(ovalIn: rect).addClip()
        NSGradient(colors: [NSColor(white: 1, alpha: 0.95), NSColor(white: 1, alpha: 0)])!
            .draw(in: rect, relativeCenterPosition: .zero)
        ctx.restoreGState()
    }
    ctx.saveGState()
    NSBezierPath(ovalIn: ballRect).addClip()
    let hi = CGRect(x: ballRect.minX - ballR * 0.2, y: ballRect.minY + ballR * 0.7,
                    width: ballR * 1.6, height: ballR * 1.6)
    NSGradient(colors: [NSColor(white: 1, alpha: 0.5), NSColor(white: 1, alpha: 0)])!
        .draw(in: hi, relativeCenterPosition: .zero)
    ctx.restoreGState()
    ctx.restoreGState()

    // rim
    let rim = NSBezierPath(ovalIn: ballRect.insetBy(dx: S * 0.004, dy: S * 0.004))
    rim.lineWidth = max(1, S * 0.008)
    NSColor(calibratedWhite: 1, alpha: 0.35).setStroke()
    rim.stroke()

    image.unlockFocus()
    return image
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                           (256, 1), (256, 2), (512, 1), (512, 2)]
for (pt, scale) in sizes {
    let px = pt * scale
    let img = drawIcon(size: CGFloat(px))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try png.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
}
print("wrote iconset to \(out)")
