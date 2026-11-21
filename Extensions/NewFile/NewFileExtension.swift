import Cocoa
import FinderSync

/// Extension Finder Sync : ajoute « Nouveau fichier › … » au clic droit dans le vide d'une
/// fenêtre du Finder ou du bureau. L'extension est bac à sable : elle ne crée rien elle-même,
/// elle transmet la demande à snobapp (snobapp://new-file?dir=…&ext=…), qui crée le fichier,
/// le sélectionne et lance le renommage.
@objc(SnobNewFileExtension)
final class SnobNewFileExtension: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForContainer else { return nil }
        // Le Finder recopie le menu : seuls titre, image, sélecteur et tag survivent.
        let sub = NSMenu(title: "Nouveau fichier")
        sub.addItem(withTitle: "Document texte (.txt)", action: #selector(newText(_:)), keyEquivalent: "")
        sub.addItem(withTitle: "Markdown (.md)", action: #selector(newMarkdown(_:)), keyEquivalent: "")
        let menu = NSMenu(title: "")
        let parent = menu.addItem(withTitle: "Nouveau fichier", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        menu.setSubmenu(sub, for: parent)
        return menu
    }

    @IBAction func newText(_ sender: AnyObject?) { request("txt") }
    @IBAction func newMarkdown(_ sender: AnyObject?) { request("md") }

    private func request(_ ext: String) {
        guard let dir = FIFinderSyncController.default().targetedURL() else { return }
        var c = URLComponents()
        c.scheme = "snobapp"
        c.host = "new-file"
        c.queryItems = [URLQueryItem(name: "dir", value: dir.path), URLQueryItem(name: "ext", value: ext)]
        guard let url = c.url else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false            // le Finder reste au premier plan pour le renommage
        NSWorkspace.shared.open(url, configuration: config)
    }
}
