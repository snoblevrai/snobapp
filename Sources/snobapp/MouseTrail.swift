import AppKit

/// v8 : tracé visible de la souris. Une fenêtre transparente par écran, au-dessus de tout,
/// qui laisse passer les clics ; le tracé s'estompe en `lifetime` secondes.
/// Rien ne tourne quand la case est décochée, et l'animation s'arrête dès que le tracé a disparu.
final class MouseTrail {
    static let shared = MouseTrail()

    static let lifetime: TimeInterval = 0.6
    static let lineWidth: CGFloat = 5

    private struct Point { let p: NSPoint; let t: TimeInterval }
    private var points: [Point] = []
    private var windows: [NSWindow] = []
    private var monitors: [Any] = []
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private(set) var color: NSColor = .systemRed

    func update() {
        let s = Settings.shared.snapshot
        color = NSColor(hex: s.mouseTrailColor) ?? .systemRed
        s.mouseTrailEnabled ? start() : stop()
        windows.forEach { $0.contentView?.needsDisplay = true }
    }

    private func start() {
        guard monitors.isEmpty else { return }
        buildWindows()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // Le moniteur global ne reçoit pas les évènements de snobapp elle-même : d'où le local.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.add() }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.add(); return e }) {
            monitors.append(l)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.buildWindows() }
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        timer?.invalidate(); timer = nil
        points = []
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            w.contentView = TrailView(frame: NSRect(origin: .zero, size: screen.frame.size))
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            return w
        }
    }

    private func add() {
        let now = ProcessInfo.processInfo.systemUptime
        let p = NSEvent.mouseLocation
        if let last = points.last, last.p == p { return }
        points.append(Point(p: p, t: now))
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        points.removeAll { now - $0.t > Self.lifetime }
        windows.forEach { $0.contentView?.needsDisplay = true }
        if points.isEmpty { timer?.invalidate(); timer = nil }
    }

    /// Segments à dessiner (coordonnées globales Cocoa) avec leur opacité.
    fileprivate func segments() -> [(NSPoint, NSPoint, CGFloat)] {
        guard points.count > 1 else { return [] }
        let now = ProcessInfo.processInfo.systemUptime
        return (1..<points.count).map { i in
            let age = now - points[i].t
            let alpha = CGFloat(max(0, 1 - age / Self.lifetime))
            return (points[i - 1].p, points[i].p, alpha)
        }
    }
}

private final class TrailView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let origin = window?.frame.origin else { return }
        let trail = MouseTrail.shared
        // Opacité par paliers : les segments consécutifs d'un même palier forment un seul trait
        // continu (jonctions arrondies), sans superpositions ni marches à chaque segment.
        let steps: CGFloat = 16
        var path: NSBezierPath?
        var level: CGFloat = -1
        func flush() {
            guard let p = path, level > 0 else { return }
            p.lineWidth = MouseTrail.lineWidth * (0.4 + 0.6 * level)
            p.lineCapStyle = .butt
            p.lineJoinStyle = .round
            trail.color.withAlphaComponent(trail.color.alphaComponent * level).setStroke()
            p.stroke()
        }
        for (a, b, alpha) in trail.segments() {
            let l = (alpha * steps).rounded(.up) / steps
            let pa = NSPoint(x: a.x - origin.x, y: a.y - origin.y)
            let pb = NSPoint(x: b.x - origin.x, y: b.y - origin.y)
            if l != level {
                flush()
                level = l
                path = NSBezierPath()
                path?.move(to: pa)
            }
            path?.line(to: pb)
        }
        flush()
    }
}

extension NSColor {
    /// « #RRGGBB » ou « #RRGGBBAA ».
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let rgba = s.count == 6 ? (v << 8) | 0xFF : v
        self.init(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                  blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? .systemRed
        func b(_ x: CGFloat) -> Int { Int((max(0, min(1, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", b(c.redComponent), b(c.greenComponent),
                      b(c.blueComponent), b(c.alphaComponent))
    }
}
