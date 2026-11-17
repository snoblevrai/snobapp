import CSMC
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Daemon root (`snobapp --daemon`, lancé par launchd).
///
/// Rôle limité : tenir une limite inférieure au palier natif de macOS et exécuter le mode
/// décharge, en coupant l'adaptateur secteur via le SMC. La limite native (≥ 80 %) est réglée
/// par l'app et appliquée par macOS lui-même ; elle sert de plafond de sécurité.
///
/// Principes de robustesse :
/// - la logique vit dans ce daemon, indépendant de l'app : un plantage, une relance ou une
///   connexion perdue ne réactivent jamais la charge ;
/// - la limite native n'est jamais relevée à 100 % ;
/// - avant la veille et à l'arrêt, l'adaptateur est toujours rebranché : on ne laisse jamais
///   la batterie se vider sans surveillance ; au pire elle remonte au palier natif.
final class BatteryDaemon {
    static let shared = BatteryDaemon()
    static let build = "6.0"

    private var backend: SMCBackend?
    // Inactif tant que l'app n'a pas écrit de configuration.
    private var config = BatteryConfig(enabled: false)
    private var status = BatteryStatus()
    private var adapterInhibited = false
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var powerPort: IONotificationPortRef?
    private var configSource: DispatchSourceFileSystemObject?
    private var lastConfigData: Data?
    private var lastWrittenStatus: BatteryStatus?
    private var evaluateScheduled = false
    /// Signe de vie : l'état est réécrit au moins toutes les 60 s, même s'il n'a pas changé.
    private static let heartbeat: TimeInterval = 60
    /// Nombre d'écritures de l'état (diagnostic, journalisé à l'arrêt).
    private var statusWrites = 0
    // Macros IOKit non importées en Swift (IOMessage.h).
    private static let systemWillSleep: natural_t = 0xE000_0280
    private static let canSystemSleep: natural_t = 0xE000_0270
    private static let systemHasPoweredOn: natural_t = 0xE000_0300   // l'adaptateur revient quand la charge retombe à limit − 2

    func run() -> Never {
        backend = SMCBackend.detect()
        status.backend = backend?.name ?? "aucun"
        status.daemonBuild = Self.build
        NSLog("snobapp helper \(Self.build) — backend SMC : \(status.backend)")

        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { BatteryDaemon.shared.shutdown() }
        term.resume()
        Self.keep(term)

        // Changements d'alimentation (branchement, % batterie).
        if let src = IOPSNotificationCreateRunLoopSource({ _ in BatteryDaemon.shared.scheduleEvaluate() }, nil)?
            .takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        registerSleepNotifications()
        watchConfig()

        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in BatteryDaemon.shared.scheduleEvaluate() }
        evaluate()
        RunLoop.main.run()
        exit(0)
    }

    private static var retained: [AnyObject] = []
    private static func keep(_ o: AnyObject) { retained.append(o) }

    // MARK: - Boucle de contrôle

    /// Regroupe les demandes rapprochées (notifications d'alimentation, fichiers, minuterie) :
    /// au plus une évaluation toutes les 0,5 s, quoi qu'il arrive.
    func scheduleEvaluate() {
        guard !evaluateScheduled else { return }
        evaluateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            BatteryDaemon.shared.evaluateScheduled = false
            BatteryDaemon.shared.evaluate()
        }
    }

    func evaluate() {
        reloadConfigIfChanged()
        let battery = Self.readBattery()
        status.percent = battery.percent
        status.onAC = battery.onAC
        status.charging = battery.charging

        let d = Self.decide(config: config, percent: battery.percent, onAC: battery.onAC,
                            inhibited: adapterInhibited, dischargeFinished: status.dischargeFinished)
        status.dischargeFinished = d.dischargeFinished
        let wantInhibit = d.inhibit
        setAdapterInhibited(wantInhibit)
        status.adapterInhibited = adapterInhibited
        writeStatusIfNeeded()
    }

    /// v6 : n'écrit l'état que s'il a changé, ou pour le signe de vie. Avant, chaque évaluation
    /// réécrivait le fichier, ce qui réveillait la surveillance du dossier → boucle infinie.
    private func writeStatusIfNeeded(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        var comparable = status
        comparable.updated = lastWrittenStatus?.updated ?? 0
        let changed = comparable != lastWrittenStatus
        let stale = now - (lastWrittenStatus?.updated ?? 0) >= Self.heartbeat
        guard force || changed || stale else { return }
        status.updated = now
        status.writeJSON(to: HelperPaths.status)
        lastWrittenStatus = status
        statusWrites += 1
    }

    /// Relit la configuration seulement si son contenu a changé.
    @discardableResult
    private func reloadConfigIfChanged() -> Bool {
        guard let data = FileManager.default.contents(atPath: HelperPaths.config), data != lastConfigData else {
            return false
        }
        lastConfigData = data
        if let c = try? JSONDecoder().decode(BatteryConfig.self, from: data) { config = c }
        return true
    }

    /// Décision pure (testée par `--selftest`) : couper l'adaptateur ou non.
    static func decide(config: BatteryConfig, percent: Int, onAC: Bool, inhibited: Bool,
                       dischargeFinished: Double, sail: Int = 2) -> (inhibit: Bool, dischargeFinished: Double) {
        let limit = min(max(config.limit, 20), 100)
        var finished = dischargeFinished
        // Adaptateur coupé : macOS peut alors annoncer « sur batterie ». On ne s'y fie pas
        // (sinon on rebrancherait aussitôt) ; seul le pourcentage décide. Si le câble est
        // réellement débranché, garder CHIE actif est sans effet et sera levé sous limit − sail.
        guard config.enabled, onAC || inhibited, percent > 0 else { return (false, finished) }

        if config.dischargeRequest != 0 && config.dischargeRequest != finished {
            if percent > limit { return (true, finished) }
            finished = config.dischargeRequest            // décharge terminée
        }
        // Limite sous le palier natif : on « navigue » entre limit − sail et limit.
        if limit < config.nativeCap {
            if percent > limit { return (true, finished) }
            if inhibited && percent > limit - sail { return (true, finished) }
        }
        return (false, finished)
    }

    private func setAdapterInhibited(_ on: Bool) {
        guard let backend, on != adapterInhibited else { return }
        if backend.inhibitAdapter(on) {
            adapterInhibited = on
            NSLog("snobapp helper: adaptateur \(on ? "coupé (décharge)" : "rebranché")")
        } else {
            NSLog("snobapp helper: écriture SMC refusée (\(backend.name))")
        }
    }

    /// Remet le Mac dans l'état par défaut : adaptateur actif.
    private func releaseAdapter() {
        if let backend { _ = backend.inhibitAdapter(false) }
        adapterInhibited = false
    }

    private func shutdown() {
        releaseAdapter()
        status.adapterInhibited = false
        writeStatusIfNeeded(force: true)
        NSLog("snobapp helper: arrêt (\(statusWrites) écritures d'état depuis le démarrage)")
        exit(0)
    }

    // MARK: - Veille

    private func registerSleepNotifications() {
        rootPort = IORegisterForSystemPower(nil, &powerPort, { _, _, type, arg in
            BatteryDaemon.shared.powerEvent(type: type, arg: arg)
        }, &notifier)
        if let powerPort {
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               IONotificationPortGetRunLoopSource(powerPort).takeUnretainedValue(), .defaultMode)
        }
    }

    private func powerEvent(type: natural_t, arg: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: arg)
        switch type {
        case Self.systemWillSleep:
            // Pendant la veille, personne ne surveille : on rebranche l'adaptateur.
            releaseAdapter()
            IOAllowPowerChange(rootPort, notificationID)
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, notificationID)
        case Self.systemHasPoweredOn:
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { BatteryDaemon.shared.scheduleEvaluate() }
        default:
            break
        }
    }

    // MARK: - Configuration

    private func watchConfig() {
        try? FileManager.default.createDirectory(atPath: HelperPaths.directory, withIntermediateDirectories: true)
        // Hors de l'index Spotlight : ces fichiers techniques n'ont rien à y faire.
        FileManager.default.createFile(atPath: HelperPaths.directory + "/.metadata_never_index", contents: nil)
        if !FileManager.default.fileExists(atPath: HelperPaths.config) { BatteryConfig(enabled: false).writeJSON(to: HelperPaths.config) }
        // L'écriture atomique remplace le fichier : on surveille le dossier.
        let fd = open(HelperPaths.directory, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        // Le dossier change aussi quand on écrit l'état : on ne réagit qu'à une config modifiée.
        src.setEventHandler {
            if BatteryDaemon.shared.reloadConfigIfChanged() { BatteryDaemon.shared.scheduleEvaluate() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configSource = src
    }

    // MARK: - Batterie

    static func readBattery() -> (percent: Int, onAC: Bool, charging: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (0, false, false)
        }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            return (max > 0 ? cur * 100 / max : cur, onAC, charging)
        }
        return (0, false, false)
    }
}

/// Clés SMC de coupure de l'adaptateur, selon le firmware.
/// Constaté sur macOS 27 : seules les clés de décharge subsistent ; CHTE / CH0B / CH0C
/// (arrêt de charge) n'existent plus.
struct SMCBackend {
    let name: String
    private let key: String
    private let onBytes: [UInt8]
    private let offBytes: [UInt8]

    static func detect() -> SMCBackend? {
        guard CSSMCOpen() else { return nil }
        let candidates = [
            SMCBackend(name: "CHIE", key: "CHIE", onBytes: [0x08], offBytes: [0x00]),
            SMCBackend(name: "CH0J", key: "CH0J", onBytes: [0x01], offBytes: [0x00]),
            SMCBackend(name: "CH0I", key: "CH0I", onBytes: [0x01], offBytes: [0x00]),
        ]
        var buf = [UInt8](repeating: 0, count: 32)
        var type: UInt32 = 0
        return candidates.first { c in
            CSSMCRead(c.key, &buf, &type) == c.onBytes.count
        }
    }

    func inhibitAdapter(_ on: Bool) -> Bool {
        let bytes = on ? onBytes : offBytes
        return bytes.withUnsafeBufferPointer { CSSMCWrite(key, $0.baseAddress, UInt32($0.count)) == 0 }
    }
}
