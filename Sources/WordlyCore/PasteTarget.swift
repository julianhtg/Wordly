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
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return false }
        let element = focused as! AXUIElement

        var role: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if let role = role as? String, textRoles.contains(role) { return true }

        // A settable AXValue or the presence of a selected-text range are strong
        // "this is an editable text control" signals — covers web/Electron views
        // that report generic roles (Slack, browsers, VS Code).
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
                element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue { return true }

        var selectedRange: AnyObject?
        if AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &selectedRange) == .success {
            return true
        }
        return false
    }
}
