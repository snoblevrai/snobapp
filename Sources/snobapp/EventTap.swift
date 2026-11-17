import AppKit

/// Un seul tap d'évènements pour le clic du milieu et la molette.
final class EventTap {
    static let shared = EventTap()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private init() {}

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    private static let mask: CGEventMask = [
        CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel,
    ].reduce(0) { $0 | (1 << $1.rawValue) }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.mask,
            callback: { _, type, event, _ in EventTap.shared.handle(type: type, event: event) },
            userInfo: nil
        ) else {
            NSLog("snobapp: création du tap impossible (permission Accessibilité ?)")
            return false
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS coupe un tap jugé trop lent : on le réarme immédiatement.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .scrollWheel:
            if SmoothScroller.isOurs(event) { break }          // nos évènements lissés
            let s = Settings.shared.snapshot
            MouseScroll.process(event, settings: s)
            // v5 : molette de souris lissée (le trackpad garde son propre défilement).
            if s.smoothScrollEnabled, !MouseScroll.isFromTouchSurface(event),
               event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 || s.smoothContinuous,
               SmoothScroller.shared.absorb(event, smoothness: s.smoothness) {
                return nil
            }
        default:
            _ = MiddleClickEngine.shared.rewriteClick(event, type: type)
        }
        return Unmanaged.passUnretained(event)
    }
}
