import AppKit

/// Handles paste-to-previous-app via CGEvent ⌘V injection.
/// The panel is closed first, then ⌘V is sent after a short delay
/// to ensure the previous app has focus.
enum PasteService {
    /// Copy content to the system pasteboard and simulate ⌘V in the frontmost app.
    static func pasteToFrontApp(content: String, close: @escaping () -> Void) {
        // 1. Copy to pasteboard.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)

        // 2. Close the panel (returns focus to previous app).
        close()

        // 3. After a short delay, send ⌘V to the now-frontmost app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            simulatePaste()
        }
    }

    /// Simulate ⌘V keypress via CGEvent.
    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code 9 = V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
