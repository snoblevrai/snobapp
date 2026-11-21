import AppKit
import FinderSync

/// v9 : « Nouveau fichier » au clic droit du Finder. L'extension (Extensions/NewFile, bac à sable)
/// envoie snobapp://new-file?dir=…&ext=… ; snobapp crée le fichier, le sélectionne dans le Finder
/// et appuie sur Entrée pour lancer le renommage, comme sous Windows.
enum NewFile {
    static let extensionID = "io.github.snoblevrai.snobapp.newfile"
    static let baseName = "Nouveau fichier"
    static let allowedExtensions: Set<String> = ["txt", "md"]

    static func handle(_ url: URL) {
        guard url.scheme == "snobapp", url.host == "new-file",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let dir = query.first(where: { $0.name == "dir" })?.value,
              let ext = query.first(where: { $0.name == "ext" })?.value, allowedExtensions.contains(ext),
              // La demande vient du menu du Finder, qui est donc au premier plan. Sinon (lien
              // snobapp:// ouvert depuis une page web, par exemple), on ignore.
              let finder = NSWorkspace.shared.frontmostApplication, finder.bundleIdentifier == "com.apple.finder"
        else { return }
        guard let file = create(in: URL(fileURLWithPath: dir, isDirectory: true), ext: ext) else {
            NSSound.beep()          // dossier en lecture seule, disque plein…
            return
        }
        selectAndRename(file, in: finder)
    }

    /// Crée « Nouveau fichier.ext », sinon « Nouveau fichier 2.ext »… sans jamais rien écraser.
    static func create(in dir: URL, ext: String) -> URL? {
        for n in 1...999 {
            let url = dir.appendingPathComponent(n == 1 ? "\(baseName).\(ext)" : "\(baseName) \(n).\(ext)")
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 { close(fd); return url }
            if errno != EEXIST { return nil }
        }
        return nil
    }

    /// Sélection par AppleScript (autorisation « Automatisation › Finder », demandée une fois),
    /// puis Entrée envoyée au Finder (autorisation Accessibilité, déjà accordée à snobapp).
    static func selectAndRename(_ file: URL, in finder: NSRunningApplication) {
        let path = file.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to select (POSIX file \"\(path)\" as alias)")?
            .executeAndReturnError(&error)
        if let error { NSLog("snobapp nouveau fichier : sélection impossible : \(error)"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard NSWorkspace.shared.frontmostApplication == finder else { return }
            for down in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)?.postToPid(finder.processIdentifier)
            }
        }
    }

    // MARK: - Activation de l'extension (case du menu)

    /// `pluginkit -m` (~5 ms) : FIFinderSyncController.isExtensionEnabled renvoie toujours false
    /// pour une extension signée ad hoc (vérifié sur macOS 27), et coûte 90 ms au premier appel.
    static var isEnabled: Bool { pluginkit(["-m", "-i", extensionID])?.hasPrefix("+") == true }

    /// `pluginkit -e use|ignore` : même effet que la case dans Réglages Système › Extensions.
    static func setEnabled(_ on: Bool) {
        if pluginkit(["-e", on ? "use" : "ignore", "-i", extensionID]) == nil, on {
            FIFinderSyncController.showExtensionManagementInterface()
        }
    }

    /// Sortie de pluginkit, ou nil s'il échoue.
    private static func pluginkit(_ args: [String]) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        p.arguments = args
        p.standardOutput = out
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
