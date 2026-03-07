import AppKit

/// Handles paste-to-previous-app via CGEvent ⌘V injection.
/// The panel is closed first, then ⌘V is sent after a short delay
/// to ensure the previous app has focus.
enum PasteService {
    /// Copy a text string to the system pasteboard and simulate ⌘V in the frontmost app.
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

    /// Copy image data to the system pasteboard and simulate ⌘V in the frontmost app.
    ///
    /// The thumbnail stored by clipsterd is a JPEG. We round-trip it through NSImage so we
    /// can write the canonical TIFF representation that most apps (Slack, Notes, Pages, etc.)
    /// expect when reading `NSPasteboard.PasteboardType.tiff`. PNG is also written as a
    /// fallback for apps that prefer `public.png`.
    static func pasteImageToFrontApp(jpegData: Data, close: @escaping () -> Void) {
        // 1. Decode JPEG → NSImage → TIFF + PNG.
        guard let image = NSImage(data: jpegData) else {
            // Thumbnail unreadable — nothing useful to paste.
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Write TIFF (primary).
        if let tiff = image.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }

        // Write PNG (secondary fallback).
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: NSPasteboard.PasteboardType("public.png"))
        }

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
