import AppKit

/// Interception des clics (clic du milieu) et de la molette, sur un thread dédié.
///
/// v7.3 : deux taps distincts, chacun actif seulement quand il sert.
/// - Clics : seulement si le clic du milieu est activé.
/// - Molette : seulement si une **souris externe est branchée** et qu'une fonction de molette
///   est active. macOS ne sait pas filtrer un tap par appareil : tant qu'il est actif, il voit
///   aussi le défilement du trackpad (laissé passer aussitôt). Sans souris, il est coupé et le
///   trackpad n'est plus du tout intercepté.
/// v7.2 : le thread dédié (priorité interactive) évite le thread principal, partagé avec le menu
/// et SwiftUI.
final class EventTap {
    static let shared = EventTap()

    private struct Tap {
        var port: CFMachPort
        var source: CFRunLoopSource
        var wanted = false
    }

    private let lock = NSLock()
    private var clickTap: Tap?
    private var scrollTap: Tap?
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

    private static func mask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(0) { $0 | (1 << $1.rawValue) }
    }

    private func makeTap(_ mask: CGEventMask, scroll: Bool) -> Tap? {
        let callback: CGEventTapCallBack = scroll
            ? { _, type, event, _ in EventTap.shared.handleScroll(type: type, event: event) }
            : { _, type, event, _ in EventTap.shared.handleClick(type: type, event: event) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback, userInfo: nil) else { return nil }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)!
        let loop = tapRunLoop()
        CFRunLoopAddSource(loop, source, .commonModes)
        CFRunLoopWakeUp(loop)
        CGEvent.tapEnable(tap: port, enable: false)   // activé par update()
        return Tap(port: port, source: source)
    }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        if clickTap == nil {
            clickTap = makeTap(Self.mask([.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]), scroll: false)
        }
        if scrollTap == nil { scrollTap = makeTap(Self.mask([.scrollWheel]), scroll: true) }
        let ok = clickTap != nil && scrollTap != nil
        lock.unlock()
        if !ok { NSLog("snobapp: création du tap impossible (permission Accessibilité ?)") }
        update()
        return ok
    }

    /// Active ou coupe chaque tap selon les réglages et la présence d'une souris.
    func update() {
        let s = Settings.shared.snapshot
        let wheelFeature = (s.reverseEnabled && (s.reverseVertical || s.reverseHorizontal))
            || s.scrollAcceleration < 0.999 || s.scrollSpeed != 1 || s.smoothScrollEnabled
        lock.lock()
        clickTap?.wanted = s.middleClickEnabled
        scrollTap?.wanted = wheelFeature && PointingDevices.shared.externalMousePresent
        for tap in [clickTap, scrollTap].compactMap({ $0 })
        where CGEvent.tapIsEnabled(tap: tap.port) != tap.wanted {
            CGEvent.tapEnable(tap: tap.port, enable: tap.wanted)
        }
        lock.unlock()
    }

    /// État pour le diagnostic : (clics, molette).
    var activeTaps: (clicks: Bool, wheel: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (clickTap.map { CGEvent.tapIsEnabled(tap: $0.port) } ?? false,
                scrollTap.map { CGEvent.tapIsEnabled(tap: $0.port) } ?? false)
    }

    func stop() {
        lock.lock()
        for tap in [clickTap, scrollTap].compactMap({ $0 }) {
            CGEvent.tapEnable(tap: tap.port, enable: false)
            if let runLoop { CFRunLoopRemoveSource(runLoop, tap.source, .commonModes) }
        }
        clickTap = nil
        scrollTap = nil
        lock.unlock()
    }

    /// macOS coupe un tap jugé trop lent : on le réarme s'il doit être actif.
    private func reenableIfWanted(scroll: Bool) {
        lock.lock()
        if let tap = scroll ? scrollTap : clickTap, tap.wanted { CGEvent.tapEnable(tap: tap.port, enable: true) }
        lock.unlock()
    }

    private func handleClick(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableIfWanted(scroll: false)
        } else {
            _ = MiddleClickEngine.shared.rewriteClick(event, type: type)
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleScroll(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableIfWanted(scroll: true)
            return Unmanaged.passUnretained(event)
        }
        // Trackpad / Magic Mouse et nos évènements lissés : rien à faire, on rend la main aussitôt.
        if SmoothScroller.isOurs(event) || MouseScroll.isFromTouchSurface(event) {
            return Unmanaged.passUnretained(event)
        }
        let s = Settings.shared.snapshot
        MouseScroll.process(event, settings: s)
        // Molette de souris lissée.
        if s.smoothScrollEnabled,
           event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 || s.smoothContinuous,
           SmoothScroller.shared.absorb(event, smoothness: s.smoothness) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
