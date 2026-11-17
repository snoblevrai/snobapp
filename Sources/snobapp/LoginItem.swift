import ServiceManagement

/// Ouverture au démarrage via SMAppService.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("snobapp: ouverture au démarrage — \(error.localizedDescription)")
        }
    }
}
