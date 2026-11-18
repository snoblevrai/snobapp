import Foundation
import IOKit.pwr_mgt

/// v7.6 : équivalent de `caffeinate -i` : le Mac ne se met pas en veille d'inactivité,
/// l'écran peut s'éteindre. macOS libère l'assertion tout seul si l'app quitte ou plante.
enum KeepAwake {
    private static var assertion: IOPMAssertionID = 0

    static func update() {
        let on = Settings.shared.snapshot.keepAwake
        if on, assertion == 0 {
            let kr = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "snobapp : anti-veille (caffeinate)" as CFString, &assertion)
            if kr != kIOReturnSuccess { assertion = 0; NSLog("snobapp: anti-veille impossible (\(kr))") }
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}
