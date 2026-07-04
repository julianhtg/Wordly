import AppKit

public enum Injector {
    /// Tag on synthetic CGEvents so our own event tap passes them through.
    public static let syntheticMarker: Int64 = 0x574F5244  // "WORD"
    static let keyV: CGKeyCode = 9  // same position on US and German layouts

    /// Paste `text` at the cursor of the frontmost app, then restore the
    /// user's clipboard. Must be called on the main thread.
    /// ponytail: no guard against overlapping paste() calls — a second call
    /// within restoreDelay would snapshot the first transcript as "the user's
    /// clipboard". AppDelegate's single-flight isProcessing gate prevents this;
    /// add serialization here only if Injector grows other callers.
    public static func paste(_ text: String,
                             pasteboard: NSPasteboard = .general,
                             restoreDelay: TimeInterval = 0.2) {
        guard !text.isEmpty else { return }
        let swapper = PasteboardSwapper(pasteboard: pasteboard)
        swapper.place(text)
        postCmdV()
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            swapper.restoreIfUnchanged()
        }
    }

    private static func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: keyV, keyDown: keyDown) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
