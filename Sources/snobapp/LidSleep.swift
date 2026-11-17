import Foundation
import IOKit
import IOKit.pwr_mgt

/// Veille à la fermeture du capot, même avec des écrans externes branchés :
/// - abonnement « IOGeneralInterest » sur IOPMrootDomain : macOS y publie
///   kIOPMMessageClamshellStateChange à chaque ouverture/fermeture du capot ;
/// - l'argument du message porte l'état (bit 0 : capot fermé) et la décision de macOS
///   (bit 1 : la fermeture provoque la veille) ;
/// - capot fermé mais macOS ne dort pas (écrans externes, mode clamshell) → IOPMSleepSystem.
/// Aucun droit root n'est nécessaire.
final class LidSleep {
    static let shared = LidSleep()

    private static let clamshellStateChange: natural_t = 0xE003_4100  // kIOPMMessageClamshellStateChange
    private static let stateBit: UInt = 1 << 0                         // kClamshellStateBit
    private static let sleepBit: UInt = 1 << 1                         // kClamshellSleepBit

    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var wasClosed = false

    private init() {}

    func start() {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            NSLog("snobapp: IOPMrootDomain indisponible, veille au capot désactivée")
            return
        }
        defer { IOObjectRelease(root) }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        wasClosed = Self.property(root, "AppleClamshellState") ?? false

        let kr = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { _, _, type, arg in
            guard type == LidSleep.clamshellStateChange else { return }
            let bits = UInt(bitPattern: arg)
            LidSleep.shared.handle(closed: bits & LidSleep.stateBit != 0,
                                   causesSleep: bits & LidSleep.sleepBit != 0)
        }, nil, &notifier)
        if kr != KERN_SUCCESS { NSLog("snobapp: abonnement capot impossible (\(kr))") }
    }

    private func handle(closed: Bool, causesSleep: Bool) {
        defer { wasClosed = closed }
        // Seulement sur la transition ouvert → fermé : réveiller le Mac capot fermé
        // (clavier externe) ne doit pas le rendormir aussitôt.
        guard closed, !wasClosed, !causesSleep else { return }
        guard Settings.shared.snapshot.lidSleepEnabled else { return }
        NSLog("snobapp: capot fermé avec écran(s) externe(s) → mise en veille")
        Self.sleepNow()
    }

    static func sleepNow() {
        let pm = IOPMFindPowerManagement(kIOMainPortDefault)
        guard pm != 0 else { return }
        let kr = IOPMSleepSystem(pm)
        if kr != kIOReturnSuccess { NSLog("snobapp: IOPMSleepSystem a échoué (\(kr))") }
        IOServiceClose(pm)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Bool? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }
}
