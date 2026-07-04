import AppKit

/// Snapshots the pasteboard, places the transcript for ⌘V, restores the
/// snapshot afterwards — unless the user copied something new in between.
public final class PasteboardSwapper {
    private let pasteboard: NSPasteboard
    private var snapshot: [NSPasteboardItem] = []
    private var changeCountAfterPlace = 0

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func place(_ text: String) {
        // ponytail: data(forType:) resolves lazy/promised flavors synchronously;
        // a slow provider stalls the paste and a failed one drops that flavor.
        // Accepted — async snapshotting only if it hurts in practice.
        snapshot = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        changeCountAfterPlace = pasteboard.changeCount
    }

    public func restoreIfUnchanged() {
        guard pasteboard.changeCount == changeCountAfterPlace else { return }
        pasteboard.clearContents()
        if !snapshot.isEmpty {
            pasteboard.writeObjects(snapshot)
        }
        snapshot = []
    }
}
