import AppKit
import IOKit

/// Évènements système qui imposent de relancer l'écoute multitouch :
/// réveil, reconfiguration d'écran (CGDisplayRegisterReconfigurationCallback)
/// et branchement d'un appareil « AppleMultitouchDevice » (notification IOKit).
/// Suit aussi l'app au premier plan pour la liste d'apps ignorées.
final class SystemMonitor {
    static let shared = SystemMonitor()

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var restartWork: DispatchWorkItem?
    private(set) var frontmostBundleID: String?

    private init() {}

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            SystemMonitor.shared.scheduleRestart(delay: 2)
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            SystemMonitor.shared.updateFrontmost(app?.bundleIdentifier)
        }
        updateFrontmost(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

        Settings.shared.onChange.append {
            SystemMonitor.shared.updateFrontmost(SystemMonitor.shared.frontmostBundleID)
        }

        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if flags.contains(.addFlag) || flags.contains(.removeFlag) {
                DispatchQueue.main.async { SystemMonitor.shared.scheduleRestart(delay: 1) }
            }
        }, nil)

        watchMultitouchDevices()
    }

    func updateFrontmost(_ bundleID: String?) {
        frontmostBundleID = bundleID
        let ignored = bundleID.map { Settings.shared.snapshot.ignoredAppBundles.contains($0) } ?? false
        MiddleClickEngine.shared.setFrontmostIgnored(ignored)
    }

    /// Regroupe les relances rapprochées (plusieurs notifications au réveil, etc.).
    func scheduleRestart(delay: TimeInterval) {
        restartWork?.cancel()
        let work = DispatchWorkItem { MiddleClickEngine.shared.restartDevices() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func watchMultitouchDevices() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let matching = IOServiceMatching("AppleMultitouchDevice")
        let result = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching, { _, iterator in
            // Vider l'itérateur réarme la notification.
            var first = true
            while case let obj = IOIteratorNext(iterator), obj != 0 { IOObjectRelease(obj); first = false }
            if !first { DispatchQueue.main.async { SystemMonitor.shared.scheduleRestart(delay: 1) } }
        }, nil, &addedIterator)
        if result == KERN_SUCCESS {
            // Vidage initial (les appareils déjà présents) sans relance.
            while case let obj = IOIteratorNext(addedIterator), obj != 0 { IOObjectRelease(obj) }
        }
    }
}

/// Permission Accessibilité : demande puis surveille jusqu'à l'octroi et démarre le tap dès qu'elle est accordée.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Appelle `onGranted` (thread principal) dès que la permission est disponible.
    static func waitForTrust(onGranted: @escaping () -> Void) {
        if isTrusted { onGranted(); return }
        prompt()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if isTrusted { timer.invalidate(); onGranted() }
        }
    }
}
