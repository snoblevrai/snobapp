import Foundation

/// Clés UserDefaults de snobapp.
enum Key {
    static let middleClickEnabled = "middleClickEnabled"
    static let fingers = "fingers"
    static let allowMoreFingers = "allowMoreFingers"
    static let tapToClick = "tapToClick"
    static let maxDistanceDelta = "maxDistanceDelta"
    static let maxTimeDelta = "maxTimeDelta"          // millisecondes
    static let ignoredAppBundles = "ignoredAppBundles"
    static let reverseEnabled = "reverseEnabled"
    static let reverseVertical = "reverseVertical"
    static let reverseHorizontal = "reverseHorizontal"
    static let scrollAcceleration = "scrollAcceleration"   // 0 (aucune) … 1 (macOS)
    static let didImportLegacySettings = "didImportLegacySettings"
    // v3
    static let lidSleepEnabled = "lidSleepEnabled"
    static let batteryLimitEnabled = "batteryLimitEnabled"
    static let batteryLimit = "batteryLimit"
    static let dischargeMode = "dischargeMode"
    static let dischargeRequestID = "dischargeRequestID"
    static let fullChargeMode = "fullChargeMode"            // v7.5
    static let didImportV3Settings = "didImportV3Settings"
    // v5
    static let smoothScrollEnabled = "smoothScrollEnabled"
    static let scrollSpeed = "scrollSpeed"                 // 0,5× … 3×
    static let smoothness = "smoothness"                   // 0 (vif) … 1 (très doux)
}

/// Instantané immuable des réglages, lu par les chemins chauds (trames tactiles ~100 Hz,
/// chaque évènement souris) sans toucher à UserDefaults.
struct SettingsSnapshot {
    var middleClickEnabled: Bool
    var fingers: Int
    var allowMoreFingers: Bool
    var tapToClick: Bool
    var maxDistanceDelta: Float
    var maxTimeDelta: TimeInterval   // secondes
    var ignoredAppBundles: Set<String>
    var reverseEnabled: Bool
    var reverseVertical: Bool
    var reverseHorizontal: Bool
    var scrollAcceleration: Double
    var lidSleepEnabled: Bool
    var batteryLimitEnabled: Bool
    var batteryLimit: Int
    var dischargeMode: Bool
    var fullChargeMode: Bool
    var smoothScrollEnabled: Bool
    var smoothness: Double
    var scrollSpeed: Double
    /// Molettes « continues » (haute résolution) : déjà fluides, on ne les relisse pas.
    var smoothContinuous: Bool { false }
}

final class Settings {
    static let shared = Settings()

    /// Valeurs par défaut : 3 doigts, mouvement 0,05, tap ≤ 300 ms, inversion verticale + horizontale.
    static let defaults: [String: Any] = [
        Key.middleClickEnabled: true,
        Key.fingers: 3,
        Key.allowMoreFingers: false,
        Key.tapToClick: true,
        Key.maxDistanceDelta: 0.05,
        Key.maxTimeDelta: 300.0,
        Key.ignoredAppBundles: [String](),
        Key.reverseEnabled: true,
        Key.reverseVertical: true,
        Key.reverseHorizontal: true,
        Key.scrollAcceleration: 0.5,
        Key.lidSleepEnabled: true,
        Key.batteryLimitEnabled: true,
        Key.batteryLimit: 80,
        Key.dischargeMode: false,
        Key.fullChargeMode: false,
        Key.smoothScrollEnabled: true,
        Key.smoothness: 0.4,
        Key.scrollSpeed: 1.0,
    ]

    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private var _snapshot: SettingsSnapshot
    /// Appelé (thread principal) après chaque changement de réglage.
    var onChange: [() -> Void] = []

    var snapshot: SettingsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return _snapshot
    }

    private init() {
        UserDefaults.standard.register(defaults: Settings.defaults)
        _snapshot = Settings.read(UserDefaults.standard)
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    private func reload() {
        let fresh = Settings.read(defaults)
        lock.lock()
        let startedDischarge = fresh.dischargeMode && !_snapshot.dischargeMode
        _snapshot = fresh
        lock.unlock()
        // Chaque activation du mode décharge reçoit un identifiant (le daemon le renvoie une
        // fois la limite atteinte, ce qui décoche le mode).
        if startedDischarge { defaults.set(Date().timeIntervalSince1970, forKey: Key.dischargeRequestID) }
        onChange.forEach { $0() }
    }

    private static func read(_ d: UserDefaults) -> SettingsSnapshot {
        SettingsSnapshot(
            middleClickEnabled: d.bool(forKey: Key.middleClickEnabled),
            fingers: max(2, min(5, d.integer(forKey: Key.fingers))),
            allowMoreFingers: d.bool(forKey: Key.allowMoreFingers),
            tapToClick: d.bool(forKey: Key.tapToClick),
            maxDistanceDelta: Float(d.double(forKey: Key.maxDistanceDelta)),
            maxTimeDelta: d.double(forKey: Key.maxTimeDelta) / 1000,
            ignoredAppBundles: Set(d.stringArray(forKey: Key.ignoredAppBundles) ?? []),
            reverseEnabled: d.bool(forKey: Key.reverseEnabled),
            reverseVertical: d.bool(forKey: Key.reverseVertical),
            reverseHorizontal: d.bool(forKey: Key.reverseHorizontal),
            scrollAcceleration: d.double(forKey: Key.scrollAcceleration),
            lidSleepEnabled: d.bool(forKey: Key.lidSleepEnabled),
            batteryLimitEnabled: d.bool(forKey: Key.batteryLimitEnabled),
            batteryLimit: max(20, min(100, d.integer(forKey: Key.batteryLimit))),
            dischargeMode: d.bool(forKey: Key.dischargeMode),
            fullChargeMode: d.bool(forKey: Key.fullChargeMode),
            smoothScrollEnabled: d.bool(forKey: Key.smoothScrollEnabled),
            smoothness: d.double(forKey: Key.smoothness),
            scrollSpeed: d.double(forKey: Key.scrollSpeed)
        )
    }

    // MARK: - Accès pratiques

    /// Écrit et met l'instantané à jour aussitôt (sans attendre la notification de UserDefaults).
    func set(_ value: Any, for key: String) {
        defaults.set(value, forKey: key)
        if Thread.isMainThread { reload() }
    }
    func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }

    var dischargeRequestID: Double { defaults.double(forKey: Key.dischargeRequestID) }

    var ignoredApps: [String] {
        get { defaults.stringArray(forKey: Key.ignoredAppBundles) ?? [] }
        set { defaults.set(Array(Set(newValue)).sorted(), forKey: Key.ignoredAppBundles) }
    }

    // MARK: - Import des réglages des apps utilisées auparavant (une seule fois)

    /// v3 : reprend la limite de charge d'AlDente (chargeVal).
    func importV3SettingsIfNeeded() {
        guard !defaults.bool(forKey: Key.didImportV3Settings) else { return }
        defer { defaults.set(true, forKey: Key.didImportV3Settings) }
        if let al = defaults.persistentDomain(forName: "com.apphousekitchen.aldente-pro"),
           let v = (al["chargeVal"] as? NSNumber)?.intValue, (20...100).contains(v) {
            defaults.set(v, forKey: Key.batteryLimit)
        }
    }

    /// Reprend les réglages existants des deux apps d'origine au premier lancement.
    func importLegacySettingsIfNeeded() {
        guard !defaults.bool(forKey: Key.didImportLegacySettings) else { return }
        defer { defaults.set(true, forKey: Key.didImportLegacySettings) }

        if let mc = defaults.persistentDomain(forName: "art.ginzburg.MiddleClick") {
            let map = [
                "fingers": Key.fingers, "allowMoreFingers": Key.allowMoreFingers,
                "tapToClick": Key.tapToClick, "maxDistanceDelta": Key.maxDistanceDelta,
                "maxTimeDelta": Key.maxTimeDelta, "ignoredAppBundles": Key.ignoredAppBundles,
            ]
            for (old, new) in map {
                if let v = mc[old] { defaults.set(v, forKey: new) }
            }
        }
        if let mos = defaults.persistentDomain(forName: "com.caldis.Mos") {
            if let v = mos["reverse"] { defaults.set(v, forKey: Key.reverseEnabled) }
            if let v = mos["reverseVertical"] { defaults.set(v, forKey: Key.reverseVertical) }
            if let v = mos["reverseHorizontal"] { defaults.set(v, forKey: Key.reverseHorizontal) }
        }
    }
}
