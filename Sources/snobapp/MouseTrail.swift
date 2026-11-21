import AppKit

/// v8 : tracé visible de la souris. Une fenêtre transparente par écran, au-dessus de tout,
/// qui laisse passer les clics ; le tracé s'estompe en `lifetime` secondes.
/// Rien ne tourne quand la case est décochée, et l'animation s'arrête dès que le tracé a disparu.
/// v8.1 : calques vectoriels (CAShapeLayer) rendus par le serveur graphique, au lieu d'un dessin
/// processeur dans une image plein écran (−90 % de processeur, −70 Mo de mémoire).
final class MouseTrail {
    static let shared = MouseTrail()

    static let lifetime: TimeInterval = 0.6
    static let lineWidth: CGFloat = 5
    /// Paliers d'opacité : un calque par palier, chaque palier est un trait continu
    /// (jonctions arrondies, sans superpositions ni marches à chaque segment).
    static let bands = 16

    private struct Point { let p: NSPoint; let t: TimeInterval }
    private var points: [Point] = []
    private var windows: [NSWindow] = []
    private var monitors: [Any] = []
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var color: NSColor = .systemRed

    func update() {
        let s = Settings.shared.snapshot
        color = NSColor(hex: s.mouseTrailColor) ?? .systemRed
        s.mouseTrailEnabled ? start() : stop()
        windows.forEach(style)
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
            // Vue « layer-hosting » : aucun dessin processeur, les traits sont des calques vectoriels.
            let root = CALayer()
            root.sublayerTransform = CATransform3DMakeTranslation(-screen.frame.minX, -screen.frame.minY, 0)
            for _ in 0..<Self.bands {
                let l = CAShapeLayer()
                l.fillColor = nil
                l.lineJoin = .round
                l.contentsScale = screen.backingScaleFactor
                root.addSublayer(l)
            }
            let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.layer = root
            v.wantsLayer = true
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            style(w)
            w.orderFrontRegardless()
            return w
        }
    }

    private func style(_ w: NSWindow) {
        for (i, l) in (w.contentView?.layer?.sublayers ?? []).compactMap({ $0 as? CAShapeLayer }).enumerated() {
            let level = CGFloat(i + 1) / CGFloat(Self.bands)
            l.strokeColor = color.withAlphaComponent(color.alphaComponent * level).cgColor
            l.lineWidth = Self.lineWidth * (0.4 + 0.6 * level)
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
        // Un chemin par palier ; l'âge croît le long du tracé, donc chaque palier est contigu.
        let paths = (0..<Self.bands).map { _ in CGMutablePath() }
        var last = -1
        for i in points.indices.dropFirst() {
            let alpha = 1 - (now - points[i].t) / Self.lifetime
            let band = min(Self.bands, Int((alpha * Double(Self.bands)).rounded(.up))) - 1
            guard band >= 0 else { continue }
            if band != last { paths[band].move(to: points[i - 1].p); last = band }
            paths[band].addLine(to: points[i].p)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for w in windows {
            for (l, p) in zip(w.contentView?.layer?.sublayers ?? [], paths) { (l as? CAShapeLayer)?.path = p }
        }
        CATransaction.commit()
        if points.isEmpty { timer?.invalidate(); timer = nil }
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
