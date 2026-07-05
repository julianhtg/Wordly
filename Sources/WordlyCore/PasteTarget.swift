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

        // Generic/web element: accept only if it's genuinely an editable text
        // region — a selected-text range AND a settable value. A focused
        // non-editable element (web content, a list row, a button) can still
        // expose a selection range, and pasting there sends ⌘V into the void
        // with no rescue; requiring editability routes those to the popup
        // instead. Sliders/steppers have a settable value but no text range, so
        // this excludes them too.
        var selectedRange: AnyObject?
        let hasSelectedRange = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &selectedRange) == .success
        var settable = DarwinBoolean(false)
        let valueSettable = AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        return hasSelectedRange && valueSettable
    }
}
