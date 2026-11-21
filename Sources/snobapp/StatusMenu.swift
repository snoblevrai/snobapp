import AppKit

/// Menu de la barre d'état : bascules rapides des deux fonctions + accès aux réglages.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    var openSettings: () -> Void = {}

    override init() {
        super.init()
        item.button?.image = Self.menuBarIcon()
        menu.delegate = self
        item.menu = menu
    }

    /// Reconstruit le menu à chaque ouverture : il reflète toujours l'état courant.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared.snapshot

        if !Accessibility.isTrusted {
            menu.addItem(action("⚠︎ Autoriser l'accès Accessibilité…", #selector(openAccessibility)))
            menu.addItem(.separator())
        }
        for app in Conflicts.running() {
            menu.addItem(action("⚠︎ Quitter \(app.localizedName ?? "l'app d'origine") (doublon)",
                                #selector(quitConflict(_:)), represented: app))
        }
        if !Conflicts.running().isEmpty { menu.addItem(.separator()) }

        menu.addItem(header("Clic du milieu"))
        menu.addItem(toggle("Activé", s.middleClickEnabled, Key.middleClickEnabled))
        menu.addItem(toggle("Taper pour cliquer", s.tapToClick, Key.tapToClick, enabled: s.middleClickEnabled))
        let fingers = NSMenuItem(title: "Doigts : \(s.fingers)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for n in 2...5 {
            let i = action("\(n) doigts", #selector(setFingers(_:)), represented: n)
            i.state = n == s.fingers ? .on : .off
            sub.addItem(i)
        }
        fingers.submenu = sub
        fingers.isEnabled = s.middleClickEnabled
        menu.addItem(fingers)
        if let id = SystemMonitor.shared.frontmostBundleID, id != Bundle.main.bundleIdentifier {
            let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? id
            let i = action("Ignorer \(name)", #selector(toggleIgnoreFrontmost(_:)), represented: id)
            i.state = s.ignoredAppBundles.contains(id) ? .on : .off
            menu.addItem(i)
        }

        menu.addItem(.separator())
        menu.addItem(header("Défilement souris"))
        menu.addItem(toggle("Inverser le sens", s.reverseEnabled, Key.reverseEnabled))

        menu.addItem(.separator())
        menu.addItem(header("Batterie"))
        let info = NSMenuItem(title: BatteryController.shared.summary, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        let discharge = action("Mode décharge (jusqu'à \(s.batteryLimit) %)", #selector(toggleDischarge))
        discharge.state = s.dischargeMode ? .on : .off
        if !s.batteryLimitEnabled { discharge.action = nil }
        menu.addItem(discharge)
        let full = action("Charger complètement (100 %)", #selector(toggleFullCharge))
        full.state = s.fullChargeMode ? .on : .off
        if !s.batteryLimitEnabled { full.action = nil }
        menu.addItem(full)

        menu.addItem(.separator())
        menu.addItem(toggle("Empêcher la veille (caffeinate)", s.keepAwake, Key.keepAwake))
        menu.addItem(toggle("Tracé de la souris", s.mouseTrailEnabled, Key.mouseTrailEnabled))
        let newFile = action("« Nouveau fichier » dans le Finder", #selector(toggleNewFile))
        newFile.state = NewFile.isEnabled ? .on : .off
        menu.addItem(newFile)
        let login = action("Ouvrir au démarrage", #selector(toggleLogin))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        let settings = action("Réglages…", #selector(showSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = action("Quitter snobapp", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// Version monochrome du logo : souris coiffée d'un haut-de-forme (image « template »).
    static func menuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let body = NSBezierPath(roundedRect: NSRect(x: 4.5, y: 0.75, width: 9, height: 11.5), xRadius: 4.5, yRadius: 4.5)
            body.lineWidth = 1.5; body.stroke()
            NSBezierPath(rect: NSRect(x: 8.4, y: 6.6, width: 1.2, height: 2.6)).fill()      // molette
            NSBezierPath(roundedRect: NSRect(x: 3, y: 11.6, width: 12, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill() // bord
            NSBezierPath(rect: NSRect(x: 5.5, y: 12.6, width: 7, height: 5.2)).fill()     // calotte
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "snobapp"
        return img
    }

    // MARK: - Fabrique d'éléments

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector, represented: Any? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        i.representedObject = represented
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ key: String, enabled: Bool = true) -> NSMenuItem {
        let i = action(title, #selector(toggleKey(_:)), represented: key)
        i.state = on ? .on : .off
        if !enabled { i.action = nil }
        return i
    }

    // MARK: - Actions

    @objc private func toggleKey(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        Settings.shared.set(!Settings.shared.bool(key), for: key)
    }

    @objc private func setFingers(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? Int else { return }
        Settings.shared.set(n, for: Key.fingers)
    }

    @objc private func toggleIgnoreFrontmost(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var list = Settings.shared.ignoredApps
        if let idx = list.firstIndex(of: id) { list.remove(at: idx) } else { list.append(id) }
        Settings.shared.ignoredApps = list
    }

    @objc private func toggleDischarge() {
        let on = !Settings.shared.snapshot.dischargeMode
        // La décharge coupe l'adaptateur via le SMC : il faut le service root.
        if on, !HelperInstaller.isInstalled || HelperInstaller.isOutdated {
            let alert = NSAlert()
            alert.messageText = "Installer le service batterie ?"
            alert.informativeText = "Le mode décharge coupe l'alimentation secteur via le contrôleur SMC, ce qui demande un petit service administrateur. macOS va demander votre mot de passe une seule fois."
            alert.addButton(withTitle: "Installer")
            alert.addButton(withTitle: "Annuler")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn, HelperInstaller.install() else { return }
        }
        if on { Settings.shared.set(false, for: Key.fullChargeMode) }   // les deux s'excluent
        Settings.shared.set(on, for: Key.dischargeMode)
        BatteryController.shared.evaluateModes()
    }

    /// v7.5 : lève la limite jusqu'à batterie pleine ; se décoche seule (pleine ou débranché).
    @objc private func toggleFullCharge() {
        let on = !Settings.shared.snapshot.fullChargeMode
        if on { Settings.shared.set(false, for: Key.dischargeMode) }
        Settings.shared.set(on, for: Key.fullChargeMode)
        BatteryController.shared.evaluateModes()
    }

    @objc private func toggleLogin() { LoginItem.set(!LoginItem.isEnabled) }
    @objc private func toggleNewFile() { NewFile.setEnabled(!NewFile.isEnabled) }
    @objc private func openAccessibility() { Accessibility.prompt(); Accessibility.openSettings() }
    @objc private func showSettings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func quitConflict(_ sender: NSMenuItem) {
        (sender.representedObject as? NSRunningApplication)?.terminate()
    }
}

/// Apps aux fonctions équivalentes : lancées en parallèle, elles doubleraient les effets
/// (double inversion = aucune) ou se disputeraient la limite de charge.
enum Conflicts {
    static let bundleIDs = ["art.ginzburg.MiddleClick", "com.caldis.Mos",
                            "com.apphousekitchen.aldente-pro", "com.kovrazhkin.Clamshell"]

    static func running() -> [NSRunningApplication] {
        bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }
}
