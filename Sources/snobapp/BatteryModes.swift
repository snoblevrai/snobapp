import Foundation

/// Logique des deux modes ponctuels du menu (v7.5), sous forme de fonction pure testée par
/// `--selftest`.
///
/// - **Charge complète** : la limite native est levée jusqu'à ce que la batterie soit pleine.
///   Se décoche quand la batterie est pleine (sur secteur), ou quand le chargeur est débranché
///   après avoir été branché. Cochée chargeur débranché, elle attend le prochain branchement.
/// - **Décharge** : l'adaptateur est coupé (service root) jusqu'à la limite. Se décoche dès que
///   la batterie est à la limite ou en dessous — sur secteur ou non, que le service ait répondu
///   ou non (avant la v7.5, seul le service pouvait la décocher, et seulement sur secteur).
/// Les deux s'excluent (géré au moment où l'on coche, dans le menu).
enum BatteryModes {
    struct State: Equatable {
        var fullCharge = false
        var sawAC = false           // charge complète : chargeur vu branché depuis l'activation
        var discharge = false
    }

    /// - onAC : alimentation secteur réellement présente (adaptateur non coupé par nous)
    /// - charged : macOS considère la batterie pleine
    static func next(_ s: State, percent: Int, onAC: Bool, charged: Bool, limit: Int) -> State {
        var n = s
        if n.fullCharge {
            if onAC {
                n.sawAC = true
                if charged || percent >= 100 { n.fullCharge = false }
            } else if n.sawAC {
                n.fullCharge = false                 // chargeur débranché
            }
            if !n.fullCharge { n.sawAC = false }
        } else {
            n.sawAC = false
        }
        if n.discharge, percent > 0, percent <= limit { n.discharge = false }
        return n
    }
}
