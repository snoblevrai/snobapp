import AppKit
import notify
import IOKit.ps
import CSMC

/// Côté app (utilisateur) de la limite de charge :
/// 1. règle la limite native de macOS sur le palier le plus proche ≥ limite (80/85/90/95/100) ;
///    macOS l'applique seul, même app fermée ou Mac en veille ;
/// 2. transmet au daemon root ce qu'il doit faire en plus (limite < palier natif, décharge).
final class BatteryController {
    static let shared = BatteryController()

    private(set) var status: BatteryStatus?
    private(set) var nativeSupported = false
    private(set) var nativeSteps: [Int] = []
    private var lastConfig: BatteryConfig?
    private var lastNativeTarget: (enabled: Bool, cap: Int)?
    var onStatusChange: [() -> Void] = []

    private init() {}

    func start() {
        nativeSupported = CSNativeLimitSupported()
        var buf = [Int32](repeating: 0, count: 16)
        let n = CSNativeLimitAvailable(&buf, 16)
        nativeSteps = buf.prefix(Int(n)).map(Int.init).sorted()
        migrateToNativeStep()
        apply()
        Settings.shared.onChange.append { BatteryController.shared.apply() }
        startNativeWatchdog()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in BatteryController.shared.refreshStatus() }
        refreshStatus()
    }

    /// Paliers proposés dans les réglages (v7.4) : seulement ceux que macOS tient sur secteur,
    /// sans solliciter la batterie (sous 80 %, il faudrait alterner décharge et recharge).
    var selectableLimits: [Int] {
        nativeSupported ? nativeSteps.filter { $0 < 100 } : Array(stride(from: 20, through: 95, by: 5))
    }

    /// v7.4 : une limite hors paliers (ex. 75 %) est remontée au palier natif suivant (80 %).
    private func migrateToNativeStep() {
        let limit = Settings.shared.snapshot.batteryLimit
        guard nativeSupported, !nativeSteps.isEmpty, !nativeSteps.contains(limit) else { return }
        let step = nativeCap(for: limit)
        NSLog("snobapp: limite \(limit) % → palier natif \(step) %")
        Settings.shared.set(step == 100 ? (nativeSteps.first ?? 80) : step, for: Key.batteryLimit)
    }

    // MARK: - Surveillance de la limite native (v7.4)

    private var watchdogToken: Int32 = 0
    private var recheckPending = false

    /// La limite native peut être désactivée ou relevée par d'autres (redémarrage, autre app
    /// comme AlDente qui la remet à 100 %, « Charger complètement » de macOS…).
    /// macOS ne publie aucune notification quand elle change par l'API système (vérifié : seule
    /// AlDente poste « com.apple.smartcharging.defaultschanged », elle-même) : on revérifie donc
    /// toutes les 60 s (2 petites requêtes), au branchement du chargeur, au réveil et au lancement.
    private func startNativeWatchdog() {
        guard nativeSupported else { return }
        notify_register_dispatch("com.apple.smartcharging.defaultschanged", &watchdogToken, .main) { _ in
            BatteryController.shared.scheduleNativeRecheck()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in BatteryController.shared.scheduleNativeRecheck(after: 5) }
        // Branchement / débranchement du chargeur : c'est là que la charge reprend.
        if let src = IOPSNotificationCreateRunLoopSource({ _ in
            BatteryController.shared.scheduleNativeRecheck(after: 2)
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in BatteryController.shared.enforceNativeLimit() }
        timer.tolerance = 15   // permet à macOS de regrouper ce réveil avec d'autres
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleNativeRecheck(after delay: TimeInterval = 1) {
        guard !recheckPending else { return }
        recheckPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            BatteryController.shared.recheckPending = false
            BatteryController.shared.enforceNativeLimit()
        }
    }

    /// Rétablit la limite native si elle ne correspond plus au réglage. Renvoie true si corrigée.
    @discardableResult
    func enforceNativeLimit() -> Bool {
        let s = Settings.shared.snapshot
        let cap = nativeCap(for: s.batteryLimit)
        guard nativeSupported, s.batteryLimitEnabled, cap < 100 else { return false }
        let current = CSNativeLimitGet(), enabled = CSNativeLimitEnabled()
        guard current != cap || !enabled else { return false }
        if current != cap { _ = CSNativeLimitSet(Int32(cap)) }
        if !CSNativeLimitEnabled() { _ = CSNativeLimitSetEnabled(true) }
        NSLog("snobapp: limite native rétablie à \(cap) % (trouvée : \(current) %, \(enabled ? "active" : "désactivée"))")
        return true
    }

    /// Palier natif appliqué pour une limite donnée.
    func nativeCap(for limit: Int) -> Int {
        guard nativeSupported, !nativeSteps.isEmpty else { return 100 }
        return nativeSteps.first { $0 >= limit } ?? 100
    }

    /// Vrai si la limite demandée ne peut être tenue que par le daemon.
    func needsHelper(_ s: SettingsSnapshot) -> Bool {
        s.batteryLimitEnabled && (s.batteryLimit < nativeCap(for: s.batteryLimit) || s.dischargeMode)
    }

    var helperInstalled: Bool { HelperInstaller.isInstalled }

    /// Le daemon a donné signe de vie récemment.
    var helperAlive: Bool {
        guard let s = status else { return false }
        return Date().timeIntervalSince1970 - s.updated < 150   // signe de vie toutes les 60 s
    }

    func apply() {
        let s = Settings.shared.snapshot
        let cap = nativeCap(for: s.batteryLimit)

        // 1. Limite native (sans root). On ne la relève jamais à 100 % quand l'app quitte :
        //    elle doit rester active app fermée, Mac en veille ou service arrêté.
        // v6 : on n'interroge PowerUI (appels XPC vers powerd) que si la cible a changé,
        // et non à chaque modification d'un réglage quelconque.
        let nativeTarget = (enabled: s.batteryLimitEnabled && cap < 100, cap: cap)
        if nativeSupported, lastNativeTarget.map({ $0 != nativeTarget }) ?? true {
            if nativeTarget.enabled {
                if CSNativeLimitGet() != cap { _ = CSNativeLimitSet(Int32(cap)) }
                if !CSNativeLimitEnabled() { _ = CSNativeLimitSetEnabled(true) }
            } else if CSNativeLimitEnabled() {
                _ = CSNativeLimitSetEnabled(false)
            }
            lastNativeTarget = nativeTarget
        }

        // 2. Consignes du daemon.
        var config = BatteryConfig()
        config.enabled = s.batteryLimitEnabled
        config.limit = s.batteryLimit
        config.nativeCap = cap
        config.dischargeRequest = s.dischargeMode ? Settings.shared.dischargeRequestID : 0
        if config != lastConfig, FileManager.default.isWritableFile(atPath: HelperPaths.directory) {
            config.writeJSON(to: HelperPaths.config)
            lastConfig = config
        }
    }

    func forceApply() { lastConfig = nil; lastNativeTarget = nil; HelperInstaller.invalidateCache(); apply() }

    func refreshStatus() {
        // Dossier du service apparu depuis (installation) : on lui envoie la configuration.
        if lastConfig == nil, FileManager.default.isWritableFile(atPath: HelperPaths.directory) { apply() }
        status = BatteryStatus.readJSON(from: HelperPaths.status)
        // Décharge terminée par le daemon → on décoche le mode.
        if let st = status, Settings.shared.snapshot.dischargeMode,
           st.dischargeFinished != 0, st.dischargeFinished == Settings.shared.dischargeRequestID {
            Settings.shared.set(false, for: Key.dischargeMode)
        }
        onStatusChange.forEach { $0() }
    }

    /// Résumé d'une ligne pour le menu.
    var summary: String {
        let s = Settings.shared.snapshot
        let battery = BatteryDaemon.readBattery()
        var parts = ["\(battery.percent) %"]
        if helperAlive, status?.adapterInhibited == true {
            parts.append(s.dischargeMode ? "décharge en cours" : "sur batterie (limite)")
        } else if battery.onAC {
            parts.append(battery.charging ? "en charge" : "charge en pause")
        } else {
            parts.append("sur batterie")
        }
        if s.batteryLimitEnabled { parts.append("max \(s.batteryLimit) %") }
        return parts.joined(separator: " · ")
    }
}

/// Installation du daemon root (une seule demande de mot de passe administrateur).
enum HelperInstaller {
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: HelperPaths.plist)
            && FileManager.default.fileExists(atPath: HelperPaths.binary)
    }

    /// Le binaire installé diffère de celui de l'app (mise à jour nécessaire).
    /// v6 : mis en cache — la fenêtre de réglages l'interrogeait chaque seconde, ce qui relisait
    /// les deux binaires (~1 Mo chacun) en entier.
    static var isOutdated: Bool {
        if let cached = outdatedCache { return cached }
        guard isInstalled, let exe = Bundle.main.executablePath else { outdatedCache = false; return false }
        // v7.3 : on compare la version de la logique du service, et non plus le binaire entier
        // (qui change à chaque version de l'app même quand le service, lui, n'a pas changé).
        if let running = BatteryStatus.readJSON(from: HelperPaths.status)?.daemonBuild, !running.isEmpty {
            let v = running != BatteryDaemon.build
            outdatedCache = v
            return v
        }
        let v = !FileManager.default.contentsEqual(atPath: exe, andPath: HelperPaths.binary)
        outdatedCache = v
        return v
    }
    private static var outdatedCache: Bool?
    static func invalidateCache() { outdatedCache = nil }

    @discardableResult
    static func install() -> Bool {
        guard let exe = Bundle.main.executablePath else { return false }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(HelperPaths.label)</string>
          <key>ProgramArguments</key><array><string>\(HelperPaths.binary)</string><string>--daemon</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ProcessType</key><string>Background</string>
        </dict></plist>
        """
        let tmp = NSTemporaryDirectory() + "\(HelperPaths.label).plist"
        guard (try? plist.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return false }
        let user = NSUserName()
        let script = [
            "launchctl bootout system/\(HelperPaths.label) 2>/dev/null; true",
            // Ancien service de l'app (nommée ClickScroll avant la v4) : on le retire.
            "for f in /Library/LaunchDaemons/*.ClickScroll.helper.plist; do [ -e \"$f\" ] && launchctl bootout system \"$f\" 2>/dev/null; rm -f \"$f\"; done; true",
            "rm -f /Library/PrivilegedHelperTools/*.ClickScroll.helper",
            "mkdir -p \(q(HelperPaths.directory)) /Library/PrivilegedHelperTools",
            "chown \(q(user)) \(q(HelperPaths.directory))",
            "cp \(q(exe)) \(q(HelperPaths.binary))",
            "chown root:wheel \(q(HelperPaths.binary)) && chmod 755 \(q(HelperPaths.binary))",
            "cp \(q(tmp)) \(q(HelperPaths.plist))",
            "chown root:wheel \(q(HelperPaths.plist)) && chmod 644 \(q(HelperPaths.plist))",
            "launchctl bootstrap system \(q(HelperPaths.plist))",
        ].joined(separator: " && ")
        let ok = runAsAdmin(script)
        if ok { BatteryController.shared.forceApply() }
        return ok
    }

    @discardableResult
    static func uninstall() -> Bool {
        let script = [
            "launchctl bootout system/\(HelperPaths.label) 2>/dev/null; true",
            "rm -f \(q(HelperPaths.plist)) \(q(HelperPaths.binary))",
        ].joined(separator: " ; ")
        defer { invalidateCache() }
        return runAsAdmin(script)
    }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func runAsAdmin(_ shell: String) -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("snobapp: installation du service — \(error)") }
        return error == nil
    }
}
