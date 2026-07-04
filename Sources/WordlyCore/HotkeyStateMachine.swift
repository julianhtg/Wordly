/// Pure gesture logic for the dictation hotkey. No CoreGraphics — fed by
/// HotkeyMonitor, fully unit-testable with synthetic timestamps (seconds).
public struct HotkeyStateMachine {
    public enum State: Equatable {
        case idle          // waiting
        case held          // key down, PTT candidate, capture running
        case tapPending    // quick release; waiting to see a second tap
        case toggling      // hands-free recording
        case toggleStopping // stop tap seen; swallowing its key-up
        case cancelled     // other key pressed during hold; swallowing our key-up
    }

    /// Effects execute in array order. Where several are returned together,
    /// `discardCapture` deliberately precedes `repostKey`/`startCapture` so the
    /// consumer never tears down a capture it just started — do not reorder.
    public enum Effect: Equatable {
        case startCapture, stopAndProcess, discardCapture, repostKey
    }

    public enum Disposition: Equatable { case consume, pass }

    public private(set) var state: State = .idle
    /// After this instant (if set), the owner must call `tick`.
    public private(set) var pendingDeadline: Double?

    public let tapWindow: Double = 0.3
    private var downTime: Double = 0
    private var upTime: Double = 0

    public init() {}

    public mutating func hotkeyDown(at t: Double) -> (Disposition, [Effect]) {
        switch state {
        case .idle:
            state = .held
            downTime = t
            return (.consume, [.startCapture])
        case .tapPending:
            pendingDeadline = nil
            if t - upTime < tapWindow {          // double-tap → hands-free
                state = .toggling
                return (.consume, [])
            }
            state = .held                        // missed tick edge: resolve tap, start fresh
            downTime = t
            return (.consume, [.discardCapture, .repostKey, .startCapture])
        case .toggling:                          // stop tap
            state = .toggleStopping
            return (.consume, [.stopAndProcess])
        case .held, .toggleStopping, .cancelled:
            return (.consume, [])                // autorepeat or glitch: inert
        }
    }

    public mutating func hotkeyUp(at t: Double) -> (Disposition, [Effect]) {
        switch state {
        case .held:
            if t - downTime >= tapWindow {       // push-to-talk release
                state = .idle
                return (.consume, [.stopAndProcess])
            }
            state = .tapPending
            upTime = t
            pendingDeadline = t + tapWindow
            return (.consume, [])
        case .toggleStopping, .cancelled:
            state = .idle
            return (.consume, [])
        case .toggling:
            return (.consume, [])                // release of the second tap
        case .idle, .tapPending:
            return (.pass, [])                   // stray
        }
    }

    public mutating func otherKeyDown(at t: Double) -> (Disposition, [Effect]) {
        switch state {
        case .held:
            state = .cancelled
            return (.pass, [.discardCapture])
        case .tapPending:                        // "^a" typed quickly
            state = .idle
            pendingDeadline = nil
            return (.pass, [.discardCapture, .repostKey])
        case .idle, .toggling, .toggleStopping, .cancelled:
            return (.pass, [])
        }
    }

    public mutating func tick(at t: Double) -> [Effect] {
        guard state == .tapPending, let deadline = pendingDeadline, t >= deadline else {
            return []
        }
        state = .idle
        pendingDeadline = nil
        return [.discardCapture, .repostKey]     // it was a plain ^ keystroke
    }
}
