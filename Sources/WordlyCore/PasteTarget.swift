import ApplicationServices

/// Heuristic: does the currently focused UI element accept typed text? Used to
/// decide between pasting the transcript (⌘V at the cursor) and popping the
/// rescue panel. Deliberately errs toward "no" — a false negative just shows
/// the copyable popup, whereas a false positive fires ⌘V into a non-text app
/// (e.g. a Finder window, where it would do nothing or trigger a shortcut).
public enum PasteTarget {
    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole,
    ]

    public static func focusedAcceptsText() -> Bool {
        let system = AXUIElementCreateSystemWide()
        // Cap the round-trip so a hung frontmost app can't freeze our main
        // thread (this runs on the main thread after every dictation).
        AXUIElementSetMessagingTimeout(system, 0.5)

        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement  // type-checked above

        var role: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if let role = role as? String, textRoles.contains(role) { return true }

        // A selected-text range is a strong "editable text control" signal that
        // web/Electron views (Slack, browsers, VS Code) expose even when they
        // report generic roles — and, unlike a settable AXValue, sliders and
        // steppers don't have it, so this avoids pasting into those.
        var selectedRange: AnyObject?
        if AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &selectedRange) == .success {
            return true
        }
        return false
    }
}
