import AppKit
import SwiftUI

/// A search text field that auto-focuses when the panel opens.
struct FocusedTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Search…"
    var onEscape: (() -> Void)?

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.isBordered = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 13)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Grab focus only once on initial display, not on every render cycle.
        if !context.coordinator.hasFocused {
            context.coordinator.hasFocused = true
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusedTextField
        var hasFocused = false

        init(_ parent: FocusedTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape?()
                return true
            }
            return false
        }
    }
}
