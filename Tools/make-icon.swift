// Génère le logo de snobapp : une souris à monocle.
//   swift Tools/make-icon.swift Resources/   → AppIcon.icns + logo.png
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func drawIcon(size s: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        let u = s / 1024  // unité

        // Fond : squircle macOS, dégradé prune → indigo.
        let inset = 100 * u
        let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                              xRadius: 185 * u, yRadius: 185 * u)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 28 * u
        shadow.shadowOffset = NSSize(width: 0, height: -12 * u)
        shadow.set()
        NSColor.black.setFill(); bg.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(red: 0.36, green: 0.16, blue: 0.55, alpha: 1),
                            NSColor(red: 0.13, green: 0.12, blue: 0.38, alpha: 1)])!
            .draw(in: bg, angle: -90)

        // Corps de la souris : capsule blanche légèrement inclinée.
        ctx.saveGState()
        ctx.translateBy(x: s / 2, y: s / 2)
        ctx.rotate(by: -0.12)
        let bodyRect = NSRect(x: -170 * u, y: -340 * u, width: 340 * u, height: 500 * u)
        let body = NSBezierPath(roundedRect: bodyRect, xRadius: 170 * u, yRadius: 170 * u)
        NSGradient(colors: [NSColor.white, NSColor(white: 0.86, alpha: 1)])!.draw(in: body, angle: -90)
        // Séparation des boutons + molette.
        NSColor(white: 0.62, alpha: 1).setStroke()
        let split = NSBezierPath()
        split.move(to: NSPoint(x: 0, y: 150 * u)); split.line(to: NSPoint(x: 0, y: -20 * u))
        split.lineWidth = 10 * u; split.stroke()
        let wheel = NSBezierPath(roundedRect: NSRect(x: -20 * u, y: 30 * u, width: 40 * u, height: 85 * u),
                                 xRadius: 22 * u, yRadius: 22 * u)
        NSColor(red: 0.36, green: 0.16, blue: 0.55, alpha: 1).setFill(); wheel.fill()

        // Monocle : anneau doré sur la partie droite, verre teinté, reflet.
        let center = NSPoint(x: 72 * u, y: -110 * u)
        let r = 92 * u
        let glass = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        NSColor(red: 0.75, green: 0.88, blue: 1, alpha: 0.45).setFill(); glass.fill()
        let gold = NSColor(red: 0.95, green: 0.74, blue: 0.24, alpha: 1)
        gold.setStroke(); glass.lineWidth = 30 * u; glass.stroke()
        let shine = NSBezierPath()
        shine.appendArc(withCenter: center, radius: r * 0.62, startAngle: 110, endAngle: 160)
        NSColor.white.withAlphaComponent(0.9).setStroke(); shine.lineWidth = 16 * u
        shine.lineCapStyle = .round; shine.stroke()
        // Chaînette.
        let chain = NSBezierPath()
        chain.move(to: NSPoint(x: center.x + r * 0.7, y: center.y - r * 0.72))
        chain.curve(to: NSPoint(x: 120 * u, y: -390 * u),
                    controlPoint1: NSPoint(x: 240 * u, y: -230 * u),
                    controlPoint2: NSPoint(x: 220 * u, y: -360 * u))
        chain.lineWidth = 12 * u; chain.setLineDash([22 * u, 12 * u], count: 2, phase: 0)
        chain.lineCapStyle = .round; gold.setStroke(); chain.stroke()
        // Haut-de-forme posé sur la souris.
        let hatColor = NSColor(white: 0.08, alpha: 1)
        let brim = NSBezierPath(roundedRect: NSRect(x: -175 * u, y: 140 * u, width: 350 * u, height: 42 * u),
                                xRadius: 21 * u, yRadius: 21 * u)
        let crown = NSBezierPath(roundedRect: NSRect(x: -118 * u, y: 165 * u, width: 236 * u, height: 215 * u),
                                 xRadius: 18 * u, yRadius: 18 * u)
        hatColor.setFill(); crown.fill(); brim.fill()
        let band = NSBezierPath(rect: NSRect(x: -118 * u, y: 182 * u, width: 236 * u, height: 40 * u))
        gold.setFill(); band.fill()
        ctx.restoreGState()
        return true
    }
}

func png(_ img: NSImage, px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = NSTemporaryDirectory() + "AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let big = drawIcon(size: 1024)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! png(big, px: px).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}
try! png(big, px: 512).write(to: URL(fileURLWithPath: "\(outDir)/logo.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "✓ \(outDir)/AppIcon.icns" : "iconutil a échoué")
