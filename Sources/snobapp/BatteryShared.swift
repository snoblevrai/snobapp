import Foundation

/// Fichiers échangés entre l'app (utilisateur) et le daemon (root).
/// Le dossier appartient à l'utilisateur (créé à l'installation) : l'app y écrit la config,
/// le daemon y écrit son état. Le daemon borne toutes les valeurs qu'il lit.
enum HelperPaths {
    static let label = "io.github.snoblevrai.snobapp.helper"
    static let binary = "/Library/PrivilegedHelperTools/\(label)"
    static let plist = "/Library/LaunchDaemons/\(label).plist"
    static let directory = ProcessInfo.processInfo.environment["SNOBAPP_HELPER_DIR"]
        ?? "/Library/Application Support/snobapp"
    static let config = directory + "/battery-config.json"
    static let status = directory + "/battery-status.json"
}

struct BatteryConfig: Codable, Equatable {
    /// Limite de charge désactivée → le daemon rebranche l'adaptateur et ne fait rien.
    var enabled = true
    var limit = 80
    /// Palier natif appliqué par macOS (≥ limit). Si limit < nativeCap, le daemon complète
    /// en coupant l'adaptateur au-dessus de `limit`.
    var nativeCap = 100
    /// ≠ 0 : décharge demandée jusqu'à `limit` (horodatage de la demande, sert d'identifiant).
    var dischargeRequest: Double = 0
}

struct BatteryStatus: Codable, Equatable {
    var percent = 0
    var onAC = false
    var charging = false
    var adapterInhibited = false
    /// Identifiant de la dernière décharge terminée (= dischargeRequest atteint).
    var dischargeFinished: Double = 0
    var backend = ""
    var updated: Double = 0
    var daemonBuild = ""
}

extension Encodable {
    func writeJSON(to path: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

extension Decodable {
    static func readJSON(from path: String) -> Self? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
