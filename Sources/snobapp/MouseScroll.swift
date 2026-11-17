import CoreGraphics
import Foundation

/// Traitement de la molette de la souris (jamais du trackpad ni de la Magic Mouse).
///
/// 1. Inversion (même principe que l'app open source Mos) :
///    on nie les trois représentations du delta de chaque axe
///    (vertical : deltaAxis1 11, fixedPtDeltaAxis1 93, pointDeltaAxis1 96 ;
///     horizontal : deltaAxis2 12, fixedPtDeltaAxis2 94, pointDeltaAxis2 97).
///    Un évènement porteur d'une phase de geste (scrollPhase 99, momentumPhase 123,
///    scrollCount 100) vient d'une surface tactile et n'est pas modifié.
///
/// 2. Accélération (v2) — macOS grossit chaque cran de molette quand on tourne vite.
///    On garde la vitesse lente telle quelle et on amortit seulement la croissance :
///      |v| ≤ base → inchangé ;  |v| > base → base · (|v| / base)^a
///    avec a = 1 (accélération macOS) … 0 (aucune : chaque cran vaut la vitesse lente).
///    `base` est appris sur le premier évènement après une pause (molette tournée lentement).
enum MouseScroll {
    private static let scrollPhase = CGEventField(rawValue: 99)!
    private static let scrollCount = CGEventField(rawValue: 100)!
    private static let momentumPhase = CGEventField(rawValue: 123)!

    /// Vrai si l'évènement provient d'une surface tactile (gestes avec phases).
    static func isFromTouchSurface(_ event: CGEvent) -> Bool {
        event.getDoubleValueField(momentumPhase) != 0
            || event.getDoubleValueField(scrollPhase) != 0
            || event.getDoubleValueField(scrollCount) != 0
    }

    // Apprentissage de la vitesse lente (accès depuis le seul thread du tap).
    private static var lastEventTime: CFAbsoluteTime = 0
    private static var baseDiscrete: Double?
    private static var baseContinuous: Double?
    private static let pause: CFAbsoluteTime = 0.3
    /// Plancher pour les molettes « continues » (haute résolution) dont le premier évènement
    /// peut être minuscule : évite d'écraser tout le défilement.
    private static let minContinuousBase = 4.0

    static func process(_ event: CGEvent, settings s: SettingsSnapshot) {
        guard !isFromTouchSurface(event) else { return }

        let reverseV = s.reverseEnabled && s.reverseVertical
        let reverseH = s.reverseEnabled && s.reverseHorizontal
        let accel = min(max(s.scrollAcceleration, 0), 1)
        let damp = accel < 0.999
        let speed = min(max(s.scrollSpeed, 0.5), 3)

        // Pas de lecture de champs inutile quand rien n'est à faire.
        guard reverseV || reverseH || damp || speed != 1 else { return }

        var factorV = 1.0, factorH = 1.0
        if damp {
            let now = CFAbsoluteTimeGetCurrent()
            let isSlowStart = now - lastEventTime > pause
            lastEventTime = now

            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let pv = Swift.abs(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            let ph = Swift.abs(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
            let magnitude = max(pv, ph)

            if isSlowStart, magnitude > 0 { learn(magnitude, continuous: continuous) }
            if let base = continuous ? baseContinuous : baseDiscrete {
                factorV = dampFactor(pv, base: base, exponent: accel)
                factorH = dampFactor(ph, base: base, exponent: accel)
            }
        }
        // 3. Vitesse (v5.1) : multiplicateur global, appliqué après l'amortissement.
        factorV *= speed; factorH *= speed
        if reverseV { factorV = -factorV }
        if reverseH { factorH = -factorH }

        if factorV != 1 {
            scale(event, factorV, .scrollWheelEventDeltaAxis1,
                  .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1)
        }
        if factorH != 1 {
            scale(event, factorH, .scrollWheelEventDeltaAxis2,
                  .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)
        }
    }

    private static func learn(_ magnitude: Double, continuous: Bool) {
        if continuous {
            let m = max(magnitude, minContinuousBase)
            baseContinuous = baseContinuous.map { $0 * 0.7 + m * 0.3 } ?? m
        } else {
            // La plus petite valeur observée après une pause est la vitesse « cran lent ».
            baseDiscrete = baseDiscrete.map { min($0 * 1.02, magnitude) } ?? magnitude
        }
    }

    /// Facteur multiplicatif ramenant |v| sur la courbe amortie.
    private static func dampFactor(_ v: Double, base: Double, exponent a: Double) -> Double {
        guard v > base, base > 0 else { return 1 }
        return base * pow(v / base, a) / v
    }

    private static func scale(_ e: CGEvent, _ f: Double,
                              _ delta: CGEventField, _ fixed: CGEventField, _ point: CGEventField) {
        // Lire les trois valeurs avant d'écrire : modifier un champ peut recalculer les autres.
        let d = e.getIntegerValueField(delta)
        let fx = e.getDoubleValueField(fixed)
        let p = e.getDoubleValueField(point)
        // Le delta « lignes » est entier : arrondi, sans jamais tomber à 0 pour un cran réel.
        var newD = Int64((Double(d) * f).rounded())
        if newD == 0 && d != 0 { newD = (Double(d) * f) < 0 ? -1 : 1 }
        e.setIntegerValueField(delta, value: newD)
        e.setDoubleValueField(fixed, value: fx * f)
        e.setDoubleValueField(point, value: p * f)
    }
}
