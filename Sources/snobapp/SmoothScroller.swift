import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore

/// Défilement fluide de la molette (v5, refondu en v7).
///
/// 1. **Étalement prédictif** : l'app mesure l'intervalle entre les crans et verse la distance
///    de chaque cran progressivement, sur ~1,2 × cet intervalle (au lieu de tout d'un coup).
///    En rotation continue, le cran suivant arrive pendant que le précédent est encore versé :
///    le débit reste quasi constant.
/// 2. Ce débit alimente l'écart `r` entre la position déjà émise et la cible, résorbé à chaque
///    rafraîchissement de l'écran par un **ressort à amortissement critique** :
///
///     r(t) = (r₀ + (ṙ₀ + ω·r₀)·t)·e^(−ωt)       (solution exacte, stable à tout pas de temps)
///
/// - la vitesse démarre de zéro et monte en douceur (pas de saut au moment du cran) ;
/// - un nouveau cran déplace la cible sans toucher à la vitesse : en rotation continue, la
///   vitesse reste quasi constante au lieu de pulser à chaque cran (défaut de la v5, qui
///   utilisait une simple décroissance exponentielle : vitesse maximale à l'instant du cran) ;
/// - fin de course sans rebond, avec la même décélération douce.
/// Les pas sont calés sur l'écran (CVDisplayLink, 120 Hz en ProMotion) et non sur une minuterie
/// libre, dont la dérive produisait de légers à-coups.
final class SmoothScroller {
    static let shared = SmoothScroller()

    /// Marque posée sur nos propres évènements (champ eventSourceUserData) pour que le tap
    /// d'évènements les laisse passer sans les retraiter.
    static let marker: Int64 = 0x534E_4F42_534D_5448  // "SNOBSMTH"

    private struct Axis {
        var r = 0.0       // reste à parcourir (px)
        var v = 0.0       // vitesse de défilement (px/s), du même signe que r en régime normal
        var carry = 0.0   // fraction de pixel pas encore émise
        var pending = 0.0 // distance des crans pas encore versée dans r
        var feedRate = 0.0 // débit de versement (px/s)
        var idle: Bool { r == 0 && v == 0 && pending == 0 }
    }

    private let lock = NSLock()
    private var y = Axis(), x = Axis()
    private var flags: CGEventFlags = []
    private var omega = 1 / 0.03
    /// Intervalle estimé entre deux crans (s), moyenne glissante.
    private var notchInterval = 0.08
    private var lastNotch: CFTimeInterval = 0
    private static let spread = 1.2
    private var lastTick: CFTimeInterval = 0
    private var running = false
    private var displayLink: CVDisplayLink?
    private var fallbackTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "snobapp.smoothscroll", qos: .userInteractive)

    /// Tests : reçoit les pixels entiers émis (dy, dx), à la place d'un vrai évènement.
    var testOutput: ((Int32, Int32) -> Void)?
    /// Tests : reçoit le déplacement vertical exact (non arrondi) de chaque image.
    var testStep: ((Double) -> Void)?
    var isAnimating: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private init() {}

    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// Constante de temps du ressort (s) pour une douceur 0…1 : 25 ms (vif) → 60 ms (doux).
    /// v7.1 : plancher relevé (15 → 25 ms) pour garder une vitesse régulière même en mode vif.
    static func timeConstant(smoothness: Double) -> Double {
        0.025 + min(max(smoothness, 0), 1) * 0.035
    }

    /// Écran sous le curseur : c'est lui qui affiche le défilement, l'horloge doit suivre sa
    /// fréquence (v7.1 — avant, l'horloge suivait l'écran principal : 60 Hz sur le Mac alors que
    /// l'écran externe affichait à 240 Hz, d'où des pas qui restaient 4 images à l'écran).
    static var testDisplay: CGDirectDisplayID?

    static func displayUnderCursor() -> CGDirectDisplayID {
        if let testDisplay { return testDisplay }
        guard let loc = CGEvent(source: nil)?.location else { return CGMainDisplayID() }
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(loc, 1, &id, &count) == .success, count > 0 else { return CGMainDisplayID() }
        return id
    }

    /// Fréquence de l'horloge actuelle (Hz), pour le diagnostic.
    var clockRate: Double {
        lock.lock(); defer { lock.unlock() }
        guard let link = displayLink else { return fallbackTimer == nil ? 0 : 120 }
        let p = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
        return p.timeValue > 0 ? Double(p.timeScale) / Double(p.timeValue) : 0
    }

    /// Durée pour parcourir 95 % d'un cran isolé (affichée dans les réglages), par simulation.
    static func settleTime(smoothness: Double) -> Double {
        var a = Axis(pending: 100, feedRate: 100 / (0.08 * spread))
        let w = 1 / timeConstant(smoothness: smoothness), dt = 1.0 / 240
        var done = 0.0, t = 0.0
        while done < 95 && t < 2 { done += advance(&a, dt: dt, omega: w); t += dt }
        return t
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
        let now = CACurrentMediaTime()
        let gap = now - lastNotch
        lastNotch = now
        if gap < 0.2 { notchInterval = 0.5 * notchInterval + 0.5 * min(max(gap, 0.03), 0.15) }
        let feedTime = notchInterval * Self.spread
        Self.add(dy, to: &y, feedTime: feedTime)
        Self.add(dx, to: &x, feedTime: feedTime)
        flags = event.flags
        omega = 1 / Self.timeConstant(smoothness: smoothness)
        // Horloge encore en place (arrêt pas encore exécuté) : on la réutilise.
        let needsStart = !running && displayLink == nil && fallbackTimer == nil
        if !running { running = true; lastTick = CACurrentMediaTime() }
        let link = displayLink
        lock.unlock()

        // Horloge déjà active : si le curseur a changé d'écran, elle le suit.
        if let link {
            let target = Self.displayUnderCursor()
            if CVDisplayLinkGetCurrentCGDisplay(link) != target { CVDisplayLinkSetCurrentCGDisplay(link, target) }
        }

        if needsStart { startClock() }
        return true
    }

    private static func add(_ d: Double, to a: inout Axis, feedTime: Double) {
        guard d != 0 else { return }
        // Changement de sens : on abandonne l'élan en cours pour répondre immédiatement.
        let moving = a.pending != 0 ? a.pending : (a.r != 0 ? a.r : a.v)
        if moving != 0, (d > 0) != (moving > 0) { a = Axis() }
        a.pending = min(max(a.pending + d, -6000), 6000)
        a.feedRate = Swift.abs(a.pending) / feedTime
    }

    // MARK: - Horloge calée sur l'écran

    private func startClock() {
        var link: CVDisplayLink?
        if CVDisplayLinkCreateWithCGDisplay(Self.displayUnderCursor(), &link) == kCVReturnSuccess, let link {
            CVDisplayLinkSetOutputHandler(link) { _, _, _, _, _ in
                SmoothScroller.shared.tick()
                return kCVReturnSuccess
            }
            lock.lock(); displayLink = link; lock.unlock()
            CVDisplayLinkStart(link)
            return
        }
        // Repli : minuterie à 120 Hz.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .microseconds(500))
        t.setEventHandler { SmoothScroller.shared.tick() }
        lock.lock(); fallbackTimer = t; lock.unlock()
        t.resume()
    }

    /// Arrêt hors du rappel de l'horloge (CVDisplayLinkStop y attendrait sa propre fin).
    private func stopClock() {
        queue.async {
            let s = SmoothScroller.shared
            s.lock.lock()
            guard !s.running else { s.lock.unlock(); return }   // relancé entre-temps
            let link = s.displayLink, timer = s.fallbackTimer
            s.displayLink = nil; s.fallbackTimer = nil
            s.lock.unlock()
            if let link { CVDisplayLinkStop(link) }
            timer?.cancel()
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        lock.lock()
        guard running else { lock.unlock(); return }
        let dt = min(max(now - lastTick, 0.001), 0.05)
        lastTick = now
        let stepY = Self.advance(&y, dt: dt, omega: omega)
        let stepX = Self.advance(&x, dt: dt, omega: omega)
        let done = y.idle && x.idle
        // En fin d'animation, la fraction restante est arrondie et émise (rien ne se perd).
        let outY = Self.take(stepY, from: &y, final: done)
        let outX = Self.take(stepX, from: &x, final: done)
        let currentFlags = flags
        if done { running = false }
        let stepHook = testStep
        lock.unlock()

        stepHook?(stepY)
        if outY != 0 || outX != 0 { post(dy: outY, dx: outX, flags: currentFlags) }
        if done { stopClock() }
    }

    /// Fait avancer le ressort d'un axe de `dt` ; renvoie la distance parcourue pendant ce pas.
    private static func advance(_ a: inout Axis, dt: Double, omega w: Double) -> Double {
        guard !a.idle else { return 0 }
        // Versement progressif des crans dans l'écart à résorber.
        if a.pending != 0 {
            let f = min(Swift.abs(a.pending), a.feedRate * dt)
            let signed = a.pending > 0 ? f : -f
            a.pending -= signed
            if Swift.abs(a.pending) < 1e-9 { a.pending = 0 }
            a.r += signed
        }
        // Écart e = r, dérivée ė = −v ; solution critique exacte.
        let e0 = a.r, de0 = -a.v
        let b = de0 + w * e0
        let decay = exp(-w * dt)
        var e1 = (e0 + b * dt) * decay
        var de1 = (b - w * (e0 + b * dt)) * decay
        // Pas de rebond : si l'on dépasse la cible, on s'y arrête.
        if e0 != 0, e1 != 0, (e1 > 0) != (e0 > 0) { e1 = 0; de1 = 0 }
        // Fin de course : tout versé, reliquat sous le demi-pixel et vitesse négligeable.
        if a.pending == 0 && Swift.abs(e1) < 0.5 && Swift.abs(de1) < 20 { e1 = 0; de1 = 0 }
        a.r = e1
        a.v = -de1
        return e0 - e1
    }

    private static func take(_ step: Double, from a: inout Axis, final: Bool) -> Int32 {
        a.carry += step
        let out = a.carry.rounded(final ? .toNearestOrAwayFromZero : .towardZero)
        a.carry -= out
        if final { a.carry = 0 }
        return Int32(out)
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
