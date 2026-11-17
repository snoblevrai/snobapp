import AppKit
import CMultitouch
import CSMC

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu!
    private let settingsWindow = SettingsWindowController()
    private var lastFingers = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.shared.importLegacySettingsIfNeeded()
        Settings.shared.importV3SettingsIfNeeded()
        lastFingers = Settings.shared.snapshot.fingers

        statusMenu = StatusMenu()
        statusMenu.openSettings = { [weak self] in self?.settingsWindow.show() }

        Settings.shared.onChange.append { [weak self] in
            guard let self else { return }
            let fingers = Settings.shared.snapshot.fingers
            if fingers != self.lastFingers {
                self.lastFingers = fingers
                MiddleClickEngine.shared.restartDevices()
            }
        }

        SystemMonitor.shared.start()
        LidSleep.shared.start()
        BatteryController.shared.start()
        MiddleClickEngine.shared.start()
        Accessibility.waitForTrust { EventTap.shared.start() }

        // Au premier lancement (ou si la permission manque), ouvrir les réglages.
        if !Accessibility.isTrusted { settingsWindow.show() }
    }

    /// Relancer l'app depuis le Finder ouvre les réglages.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        EventTap.shared.stop()
        MiddleClickEngine.shared.stop()
    }
}

// `snobapp --daemon` : service root lancé par launchd (limite de charge, décharge).
if CommandLine.arguments.contains("--daemon") {
    BatteryDaemon.shared.run()
}

// `snobapp --render-settings fichier.png` : dessine la fenêtre de réglages (diagnostic).
if let i = CommandLine.arguments.firstIndex(of: "--render-settings"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    Settings.shared.importV3SettingsIfNeeded()
    BatteryController.shared.start()
    let tab = i + 2 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 2]) ?? 0 : 0
    SettingsWindowController.render(to: CommandLine.arguments[i + 1], tab: tab)
    exit(0)
}

// `snobapp --selftest` : vérifie le pont MultitouchSupport sans interface ni permission.
if CommandLine.arguments.contains("--selftest") {
    do {
        guard CSMultitouchLoad() else { print("MultitouchSupport: ÉCHEC du chargement"); exit(1) }
        let n = CSMultitouchStart()
        print("MultitouchSupport: OK, \(n) appareil(s)")
        CSMultitouchStop()
        print("Accessibilité accordée: \(AXIsProcessTrusted())")
        print("SMC (adaptateur): \(SMCBackend.detect()?.name ?? "aucune clé")")
        var steps = [Int32](repeating: 0, count: 16)
        let stepCount = CSNativeLimitAvailable(&steps, 16)
        print("Limite native: supportée=\(CSNativeLimitSupported()) paliers=\(steps.prefix(Int(stepCount))) actuelle=\(CSNativeLimitGet()) active=\(CSNativeLimitEnabled())")
        print("Batterie: \(BatteryDaemon.readBattery())")
        // Scénarios du daemon : (config, %, secteur, adaptateur coupé, décharge finie) → couper ?
        func cfg(_ limit: Int, cap: Int, discharge: Double = 0) -> BatteryConfig {
            BatteryConfig(enabled: true, limit: limit, nativeCap: cap, dischargeRequest: discharge)
        }
        let cases: [(String, BatteryConfig, Int, Bool, Bool, Bool)] = [
            ("75 % / palier 80, batterie 86 → couper", cfg(75, cap: 80), 86, true, false, true),
            ("75 % / palier 80, batterie 75 → secteur", cfg(75, cap: 80), 75, true, false, false),
            ("75 % coupé, batterie 74 → rester coupé (navigation)", cfg(75, cap: 80), 74, false, true, true),
            ("75 % coupé, batterie 73 → rebrancher", cfg(75, cap: 80), 73, false, true, false),
            ("80 % natif, batterie 86 → macOS gère, secteur", cfg(80, cap: 80), 86, true, false, false),
            ("décharge vers 80, batterie 86 → couper", cfg(80, cap: 80, discharge: 1), 86, true, false, true),
            ("décharge vers 80, batterie 80 → fin, secteur", cfg(80, cap: 80, discharge: 1), 80, true, true, false),
            ("débranché, non coupé → rien", cfg(75, cap: 80), 90, false, false, false),
        ]
        var failures = 0
        for (name, c, pct, ac, inh, expected) in cases {
            let r = BatteryDaemon.decide(config: c, percent: pct, onAC: ac, inhibited: inh, dischargeFinished: 0)
            let ok = r.inhibit == expected
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(name)\(c.dischargeRequest != 0 ? " [décharge finie: \(r.dischargeFinished == 1)]" : "")")
        }
        // Tap à 3 doigts reconstitué à partir des seules transitions (v6.1).
        var tapSettings = Settings.shared.snapshot
        tapSettings.middleClickEnabled = true; tapSettings.tapToClick = true
        tapSettings.fingers = 3; tapSettings.allowMoreFingers = false
        tapSettings.maxTimeDelta = 0.3; tapSettings.maxDistanceDelta = 0.05
        MiddleClickEngine.shared.setFrontmostIgnored(false)
        let p = SIMD2<Float>(1.5, 1.2), moved = SIMD2<Float>(1.8, 1.2), z = SIMD2<Float>(0, 0)
        let tapCases: [(String, [(Int, SIMD2<Float>, SIMD2<Float>, Double)], Bool)] = [
            ("tap rapide 3 doigts → clic", [(1, z, z, 0), (3, p, z, 0.02), (0, z, p, 0.12)], true),
            ("3 doigts qui glissent → pas de clic", [(3, p, z, 0), (0, z, moved, 0.15)], false),
            ("appui long 3 doigts → pas de clic", [(3, p, z, 0), (0, z, p, 0.6)], false),
            ("4 doigts → pas de clic", [(3, p, z, 0), (4, z, p, 0.03), (0, z, p, 0.1)], false),
            ("1 doigt (curseur) → pas de clic", [(1, z, z, 0), (0, z, z, 0.1)], false),
        ]
        for (name, steps, expected) in tapCases {
            let t0 = CFAbsoluteTimeGetCurrent() + 1000
            var clicked = false
            for (n, sum, last, dt) in steps {
                clicked = MiddleClickEngine.shared.transition(fingerCount: n, sum: sum, last: last,
                                                              settings: tapSettings, now: t0 + dt) || clicked
            }
            let ok = clicked == expected
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(name)")
        }

        // Vitesse : un cran de 10 px à 2× → 20 px, à 0,5× → 5 px (accélération 100 %, sans inversion).
        for (speed, expected) in [(2.0, 20.0), (0.5, 5.0), (1.0, 10.0)] {
            var snap = Settings.shared.snapshot
            snap.scrollSpeed = speed; snap.reverseEnabled = false; snap.scrollAcceleration = 1
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
            e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 10)
            MouseScroll.process(e, settings: snap)
            let got = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let ok = Swift.abs(got - expected) < 0.01
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") vitesse \(speed)× : \(got) px (attendu \(expected))")
        }

        // Défilement fluide : la distance émise doit égaler la distance reçue.
        for smooth in [0.0, 0.4, 1.0] {
            var total = (y: 0, x: 0), frames = 0
            let lock = NSLock()
            SmoothScroller.shared.testOutput = { dy, dx in lock.lock(); total.y += Int(dy); total.x += Int(dx); frames += 1; lock.unlock() }
            for (dy, dx) in [(-37.0, 0.0), (-41.0, 3.0), (-12.0, 0.0)] {
                let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)!
                e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
                e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
                _ = SmoothScroller.shared.absorb(e, smoothness: smooth)
                Thread.sleep(forTimeInterval: 0.02)
            }
            let start = Date()
            while SmoothScroller.shared.isAnimating && Date().timeIntervalSince(start) < 3 { Thread.sleep(forTimeInterval: 0.01) }
            let elapsed = Date().timeIntervalSince(start)
            let ok = total.y == -90 && total.x == 3 && !SmoothScroller.shared.isAnimating
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") lissage douceur \(smooth) : Δy=\(total.y) (attendu -90), Δx=\(total.x) (attendu 3), \(frames) images, fin \(Int(elapsed * 1000)) ms après le dernier cran")
        }
        // Régularité (v7) : crans de 40 px toutes les 60 ms ; en régime établi, la vitesse
        // (déplacement par seconde) ne doit pas pulser à chaque cran. Testé sur chaque écran.
        var displays = [CGDirectDisplayID](repeating: 0, count: 8); var displayCount: UInt32 = 0
        CGGetActiveDisplayList(8, &displays, &displayCount)
        for display in displays.prefix(Int(displayCount)) {
            SmoothScroller.testDisplay = display
            var samples: [(t: Double, step: Double)] = []
            let lock = NSLock()
            SmoothScroller.shared.testOutput = { _, _ in }
            SmoothScroller.shared.testStep = { s in lock.lock(); samples.append((CACurrentMediaTime(), s)); lock.unlock() }
            let t0 = CACurrentMediaTime()
            for _ in 0..<12 {
                let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)!
                e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -40)
                _ = SmoothScroller.shared.absorb(e, smoothness: 0.1)
                Thread.sleep(forTimeInterval: 0.06)
            }
            let rate = SmoothScroller.shared.clockRate
            while SmoothScroller.shared.isAnimating { Thread.sleep(forTimeInterval: 0.01) }
            Thread.sleep(forTimeInterval: 0.05)
            lock.lock(); let all = samples; lock.unlock()
            var speeds: [Double] = []
            for i in 1..<all.count {
                let dt = all[i].t - all[i - 1].t
                let t = all[i].t - t0
                if t > 0.30 && t < 0.66 && dt > 0.001 { speeds.append(Swift.abs(all[i].step) / dt) }
            }
            let mean = speeds.reduce(0, +) / Double(max(speeds.count, 1))
            let spread = ((speeds.max() ?? 0) - (speeds.min() ?? 0)) / max(mean, 1)
            let ok = spread < 0.25 && !speeds.isEmpty
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") régularité écran \(display) (\(Int(rate.rounded())) Hz, douceur 0,1) : écart max \(Int(spread * 100)) % (seuil 25 %), \(speeds.count) images")
        }
        SmoothScroller.testDisplay = nil
        SmoothScroller.shared.testStep = nil
        SmoothScroller.shared.testOutput = nil
        if failures > 0 { exit(3) }
        exit(n > 0 ? 0 : 2)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
