import AppKit

/// Un seul tap d'évènements pour le clic du milieu et la molette.
/// v7.2 : il tourne sur son propre thread (priorité interactive) et non plus sur le thread
/// principal, partagé avec le menu et SwiftUI : latence plus faible et indépendante de l'interface.
final class EventTap {
    static let shared = EventTap()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private init() {}

    /// Lance le thread dédié et attend que sa boucle d'évènements soit prête.
    private func tapRunLoop() -> CFRunLoop {
        if let runLoop { return runLoop }
        let ready = DispatchSemaphore(value: 0)
        var loop: CFRunLoop?
        let t = Thread {
            // Un port factice garde la boucle en vie (sans lui, run() rendrait la main aussitôt).
            RunLoop.current.add(NSMachPort(), forMode: .default)
            loop = CFRunLoopGetCurrent()
            ready.signal()
            RunLoop.current.run()   // bloque sans consommer : réveillée seulement par les évènements
        }
        t.name = "snobapp.eventtap"
        t.qualityOfService = .userInteractive
        t.start()
        ready.wait()
        thread = t
        runLoop = loop
        return loop!
    }

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
        let loop = tapRunLoop()
        CFRunLoopAddSource(loop, source, .commonModes)
        CFRunLoopWakeUp(loop)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source, let runLoop { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS coupe un tap jugé trop lent : on le réarme immédiatement.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .scrollWheel:
            // Trackpad / Magic Mouse (~100 évènements/s) et nos évènements lissés : rien à faire.
            if SmoothScroller.isOurs(event) || MouseScroll.isFromTouchSurface(event) { break }
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
