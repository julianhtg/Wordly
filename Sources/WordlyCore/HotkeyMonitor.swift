import AppKit
import CoreGraphics

/// Owns the CGEventTap, translates raw key events into state-machine calls,
/// and executes the resulting effects. Main-thread only (tap runs on the main
/// run loop).
public final class HotkeyMonitor {
    public var onStartCapture: (() -> Void)?
    public var onStopAndProcess: (() -> Void)?
    public var onDiscardCapture: (() -> Void)?

    private var machine = HotkeyStateMachine()
    private let keyCode: Int64
    private var tap: CFMachPort?
    private var tickGeneration = 0

    public init(keyCode: Int64) {
        self.keyCode = keyCode
    }

    /// Returns false if the tap can't be created (Accessibility not granted).
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                let monitor = Unmanaged<HotkeyMonitor>
                    .fromOpaque(userInfo!).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: selfPtr) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Our own re-posted ^ / synthesized ⌘V: never re-process.
        if event.getIntegerValueField(.eventSourceUserData) == Injector.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        let now = CACurrentMediaTime()
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let isOurKey = code == keyCode
        let hasModifiers = !event.flags
            .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            .isEmpty
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        let disposition: HotkeyStateMachine.Disposition
        let effects: [HotkeyStateMachine.Effect]

        switch type {
        case .keyDown where isOurKey && isAutorepeat:
            // Swallow repeats while we own the key; pass when idle.
            return machine.state == .idle ? Unmanaged.passUnretained(event) : nil
        case .keyDown where isOurKey && hasModifiers:
            // ⇧^ (°) etc. count as "other key": cancels a hold, types normally.
            (disposition, effects) = machine.otherKeyDown(at: now)
        case .keyDown where isOurKey:
            (disposition, effects) = machine.hotkeyDown(at: now)
        case .keyUp where isOurKey:
            (disposition, effects) = machine.hotkeyUp(at: now)
        case .keyDown:
            (disposition, effects) = machine.otherKeyDown(at: now)
        default:
            return Unmanaged.passUnretained(event)
        }

        run(effects)
        scheduleTickIfNeeded()
        return disposition == .consume ? nil : Unmanaged.passUnretained(event)
    }

    private func run(_ effects: [HotkeyStateMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .startCapture: onStartCapture?()
            case .stopAndProcess: onStopAndProcess?()
            case .discardCapture: onDiscardCapture?()
            case .repostKey: repostHotkey()
            }
        }
    }

    private func scheduleTickIfNeeded() {
        guard let deadline = machine.pendingDeadline else { return }
        tickGeneration += 1
        let generation = tickGeneration
        let delay = max(0, deadline - CACurrentMediaTime()) + 0.01
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.tickGeneration == generation else { return }
            self.run(self.machine.tick(at: CACurrentMediaTime()))
        }
    }

    /// Types the ^ the user actually wanted (single quick tap).
    private func repostHotkey() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: CGKeyCode(keyCode),
                                      keyDown: keyDown) else { continue }
            event.setIntegerValueField(.eventSourceUserData,
                                       value: Injector.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
