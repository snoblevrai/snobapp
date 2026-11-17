import AppKit
import CMultitouch

/// Clic du milieu au trackpad (même principe que l'app open source MiddleClick) :
/// 1. « Cliquer » avec N doigts posés : le clic gauche/droit est réécrit en clic du milieu.
/// 2. « Taper » avec N doigts : si le contact dure ≤ maxTimeDelta et que les doigts bougent
///    de moins de maxDistanceDelta (distance de Manhattan des positions normalisées cumulées),
///    un clic du milieu est synthétisé à la position du curseur.
final class MiddleClickEngine {
    static let shared = MiddleClickEngine()

    private let lock = NSLock()

    // État partagé entre le thread MultitouchSupport et le tap d'évènements (thread principal).
    private var threeDown = false             // N doigts actuellement posés
    private var wasThreeDown = false          // un « down » a été converti, convertir le « up »
    private var maybeMiddleClick = false
    private var touchStartTime: CFAbsoluteTime?
    private var pos1 = SIMD2<Float>.zero
    private var pos2 = SIMD2<Float>.zero
    private var naturalMiddleClickLastTime: CFAbsoluteTime?
    private var frontmostIgnored = false

    private init() {}

    // MARK: - Cycle de vie

    func start() {
        guard CSMultitouchLoad() else {
            NSLog("snobapp: MultitouchSupport indisponible, clic du milieu au trackpad désactivé")
            return
        }
        CSMultitouchSetPositionLimit(Int32(Settings.shared.snapshot.fingers))
        CSMultitouchSetHandler { count, sx, sy in
            MiddleClickEngine.shared.handleFrame(fingerCount: Int(count), sum: SIMD2(sx, sy))
        }
        restartDevices()
    }

    /// Relance l'écoute (réveil, nouvel appareil, changement d'écran, changement de réglage).
    func restartDevices() {
        CSMultitouchSetPositionLimit(Int32(Settings.shared.snapshot.fingers))
        let n = CSMultitouchStart()
        NSLog("snobapp: \(n) appareil(s) multitouch à l'écoute")
    }

    func stop() { CSMultitouchStop() }

    /// Mis à jour quand l'app au premier plan change (évite d'interroger NSWorkspace à chaque trame).
    func setFrontmostIgnored(_ ignored: Bool) {
        lock.lock(); frontmostIgnored = ignored; lock.unlock()
    }

    // MARK: - Trames tactiles (thread MultitouchSupport)

    private func handleFrame(fingerCount n: Int, sum: SIMD2<Float>) {
        let s = Settings.shared.snapshot
        var shouldClick = false

        lock.lock()
        defer {
            lock.unlock()
            if shouldClick { DispatchQueue.main.async { Self.postMiddleClick() } }
        }

        guard s.middleClickEnabled, !frontmostIgnored else {
            threeDown = false
            touchStartTime = nil
            return
        }

        let matches = s.allowMoreFingers ? n >= s.fingers : n == s.fingers
        threeDown = matches

        guard s.tapToClick else { return }

        if n == 0 {
            shouldClick = touchEnded(s)
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if touchStartTime == nil {
            touchStartTime = now
            maybeMiddleClick = true
            pos1 = .zero
        } else if maybeMiddleClick, let start = touchStartTime, now - start > s.maxTimeDelta {
            maybeMiddleClick = false
        }

        if n > s.fingers && !s.allowMoreFingers {
            maybeMiddleClick = false
            pos1 = .zero
        }
        if matches {
            if maybeMiddleClick {
                pos1 = sum
                pos2 = pos1
                maybeMiddleClick = false
            } else {
                pos2 = sum
            }
        }
    }

    /// Tous les doigts levés : décide s'il s'agissait d'un tap N doigts.
    private func touchEnded(_ s: SettingsSnapshot) -> Bool {
        defer { touchStartTime = nil }
        guard let start = touchStartTime, pos1 != .zero else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - start <= s.maxTimeDelta else { return false }
        let distance = Swift.abs(pos1.x - pos2.x) + Swift.abs(pos1.y - pos2.y)
        guard distance < s.maxDistanceDelta else { return false }
        // Un vrai clic (physique) du milieu vient d'avoir lieu : ne pas en émettre un second.
        if let natural = naturalMiddleClickLastTime, now - natural <= s.maxTimeDelta * 0.75 {
            return false
        }
        return true
    }

    private static func postMiddleClick() {
        let location = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: location, mouseButton: .center)?
                .post(tap: .cghidEventTap)
        }
    }

    // MARK: - Tap d'évènements (thread principal)

    /// Réécrit un clic gauche/droit en clic du milieu quand N doigts sont posés.
    /// Renvoie true si l'évènement a été modifié.
    func rewriteClick(_ event: CGEvent, type: CGEventType) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !frontmostIgnored else { return false }

        switch type {
        case .leftMouseDown, .rightMouseDown:
            guard threeDown else { return false }
            threeDown = false
            wasThreeDown = true
            naturalMiddleClickLastTime = CFAbsoluteTimeGetCurrent()
            event.type = .otherMouseDown
        case .leftMouseUp, .rightMouseUp:
            guard wasThreeDown else { return false }
            wasThreeDown = false
            event.type = .otherMouseUp
        default:
            return false
        }
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
        return true
    }
}
