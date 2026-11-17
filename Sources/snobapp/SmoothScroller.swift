import CoreGraphics
import Foundation
import QuartzCore

/// Défilement fluide de la molette (v5).
///
/// Chaque cran (déjà inversé / amorti par `MouseScroll`) est absorbé et sa distance en pixels
/// s'ajoute à une réserve. Une horloge à ~120 Hz restitue la réserve en petits évènements
/// « pixel » avec une décroissance exponentielle : à chaque image on émet
/// `réserve × (1 − e^(−dt/τ))`, τ dépendant du réglage « Douceur ».
final class SmoothScroller {
    static let shared = SmoothScroller()

    /// Marque posée sur nos propres évènements (champ eventSourceUserData) pour que le tap
    /// d'évènements les laisse passer sans les retraiter.
    static let marker: Int64 = 0x534E_4F42_534D_5448  // "SNOBSMTH"

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "snobapp.smoothscroll", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var remaining = (x: 0.0, y: 0.0)
    private var carry = (x: 0.0, y: 0.0)        // fractions de pixel non encore émises
    private var flags: CGEventFlags = []
    private var lastTick: CFTimeInterval = 0
    private var tau = 0.08

    /// Remplace l'émission réelle (tests) : reçoit (dy, dx) en pixels.
    var testOutput: ((Int32, Int32) -> Void)?
    var isAnimating: Bool { lock.lock(); defer { lock.unlock() }; return timer != nil }

    private init() {}

    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// τ (s) pour une douceur 0…1 : 0,03 s (vif) → 0,20 s (très doux).
    static func timeConstant(smoothness: Double) -> Double {
        0.03 + min(max(smoothness, 0), 1) * 0.17
    }

    /// Absorbe un évènement molette. Renvoie false si rien à animer (laisser passer l'original).
    func absorb(_ event: CGEvent, smoothness: Double) -> Bool {
        var dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        var dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        // Certains pilotes ne renseignent que le delta « lignes » : ~10 px par ligne.
        if dy == 0 { dy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * 10 }
        if dx == 0 { dx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * 10 }
        guard dx != 0 || dy != 0 else { return false }

        lock.lock()
        // Changement de sens : on repart de zéro au lieu de « freiner » l'élan précédent.
        if dy != 0, remaining.y != 0, (dy > 0) != (remaining.y > 0) { remaining.y = 0; carry.y = 0 }
        if dx != 0, remaining.x != 0, (dx > 0) != (remaining.x > 0) { remaining.x = 0; carry.x = 0 }
        remaining.y = clamp(remaining.y + dy)
        remaining.x = clamp(remaining.x + dx)
        flags = event.flags
        tau = Self.timeConstant(smoothness: smoothness)
        let needsStart = timer == nil
        if needsStart { lastTick = CACurrentMediaTime() }
        lock.unlock()

        if needsStart { start() }
        return true
    }

    /// Évite qu'une rafale de crans accumule des milliers de pixels.
    private func clamp(_ v: Double) -> Double { min(max(v, -4000), 4000) }

    private func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        lock.lock(); timer = t; lock.unlock()
        t.resume()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        lock.lock()
        let dt = max(now - lastTick, 0.001)
        lastTick = now
        let k = 1 - exp(-dt / tau)

        var stepY = remaining.y * k, stepX = remaining.x * k
        // Fin d'animation : on vide le reliquat.
        if Swift.abs(remaining.y) < 1.5 { stepY = remaining.y }
        if Swift.abs(remaining.x) < 1.5 { stepX = remaining.x }
        remaining.y -= stepY; remaining.x -= stepX

        carry.y += stepY; carry.x += stepX
        let done = remaining.y == 0 && remaining.x == 0
        // En fin d'animation, la fraction restante est arrondie et émise (rien ne se perd).
        let rule: FloatingPointRoundingRule = done ? .toNearestOrAwayFromZero : .towardZero
        let outY = carry.y.rounded(rule), outX = carry.x.rounded(rule)
        carry.y -= outY; carry.x -= outX
        let currentFlags = flags
        if done {
            timer?.cancel(); timer = nil
            carry = (0, 0)
        }
        lock.unlock()

        if outY != 0 || outX != 0 { post(dy: Int32(outY), dx: Int32(outX), flags: currentFlags) }
    }

    private func post(dy: Int32, dx: Int32, flags: CGEventFlags) {
        if let testOutput { testOutput(dy, dx); return }
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                              wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        e.post(tap: .cgSessionEventTap)
    }
}
