import Foundation
import IOKit
import IOKit.hid

/// Présence d'une souris externe (v7.3), pour n'intercepter la molette que lorsqu'il y en a une.
///
/// Détection par le registre IOKit (aucune autorisation « Surveillance de l'entrée » requise) :
/// un périphérique HID déclarant l'usage « souris » (page 1, usage 2), non intégré au Mac, et qui
/// n'est ni un trackpad (usage Digitizer/Touch Pad 13/5) ni une Magic Mouse (dont le défilement,
/// avec phases, n'est jamais modifié).
final class PointingDevices {
    static let shared = PointingDevices()

    private let lock = NSLock()
    private var present = false
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pending: DispatchWorkItem?
    var onChange: [() -> Void] = []

    private init() {}

    var externalMousePresent: Bool { lock.lock(); defer { lock.unlock() }; return present }

    func start() {
        refresh()
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var it: io_iterator_t = 0
            let kr = IOServiceAddMatchingNotification(port, type, IOServiceMatching(kIOHIDDeviceKey), { _, iterator in
                while case let obj = IOIteratorNext(iterator), obj != 0 { IOObjectRelease(obj) }
                PointingDevices.shared.scheduleRefresh()
            }, nil, &it)
            if kr == KERN_SUCCESS {
                while case let obj = IOIteratorNext(it), obj != 0 { IOObjectRelease(obj) }   // arme la notification
                iterators.append(it)
            }
        }
    }

    /// Un branchement produit plusieurs notifications (une par interface) : on les regroupe.
    private func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { PointingDevices.shared.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func refresh() {
        let now = Self.scan()
        lock.lock()
        let changed = now != present
        present = now
        lock.unlock()
        if changed {
            NSLog("snobapp: souris externe \(now ? "branchée — molette interceptée" : "absente — molette non interceptée")")
            onChange.forEach { $0() }
        }
    }

    static func scan() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        var found = false
        while case let dev = IOIteratorNext(iterator), dev != 0 {
            defer { IOObjectRelease(dev) }
            if !found, isExternalMouse(dev) { found = true }
        }
        return found
    }

    private static func isExternalMouse(_ dev: io_object_t) -> Bool {
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(dev, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        let pairs = (prop(kIOHIDDeviceUsagePairsKey) as? [[String: Any]] ?? []).map {
            (($0[kIOHIDDeviceUsagePageKey] as? Int) ?? 0, ($0[kIOHIDDeviceUsageKey] as? Int) ?? 0)
        }
        let isMouse = pairs.contains { $0 == (1, 2) }
            || ((prop(kIOHIDPrimaryUsagePageKey) as? Int) == 1 && (prop(kIOHIDPrimaryUsageKey) as? Int) == 2)
        guard isMouse else { return false }
        if (prop("Built-In") as? Bool) == true { return false }
        if pairs.contains(where: { $0 == (13, 5) }) { return false }               // trackpad
        let product = (prop(kIOHIDProductKey) as? String ?? "").lowercased()
        if product.contains("trackpad") || product.contains("magic mouse") { return false }
        return true
    }
}
