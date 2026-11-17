import AppKit
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
    var onStatusChange: [() -> Void] = []

    private init() {}

    func start() {
        nativeSupported = CSNativeLimitSupported()
        var buf = [Int32](repeating: 0, count: 16)
        let n = CSNativeLimitAvailable(&buf, 16)
        nativeSteps = buf.prefix(Int(n)).map(Int.init).sorted()
        apply()
        Settings.shared.onChange.append { BatteryController.shared.apply() }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in BatteryController.shared.refreshStatus() }
        refreshStatus()
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
        return Date().timeIntervalSince1970 - s.updated < 60
    }

    func apply() {
        let s = Settings.shared.snapshot
        let cap = nativeCap(for: s.batteryLimit)

        // 1. Limite native (sans root). On ne la relève jamais à 100 % quand l'app quitte :
        //    elle doit rester active app fermée, Mac en veille ou service arrêté.
        if nativeSupported {
            if s.batteryLimitEnabled && cap < 100 {
                if CSNativeLimitGet() != cap { _ = CSNativeLimitSet(Int32(cap)) }
                if !CSNativeLimitEnabled() { _ = CSNativeLimitSetEnabled(true) }
            } else if CSNativeLimitEnabled() {
                _ = CSNativeLimitSetEnabled(false)
            }
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

    func forceApply() { lastConfig = nil; apply() }

    func refreshStatus() {
        if lastConfig == nil { apply() }   // dossier du service créé depuis (installation)
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
    static var isOutdated: Bool {
        guard isInstalled, let exe = Bundle.main.executablePath else { return false }
        return !FileManager.default.contentsEqual(atPath: exe, andPath: HelperPaths.binary)
    }

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
