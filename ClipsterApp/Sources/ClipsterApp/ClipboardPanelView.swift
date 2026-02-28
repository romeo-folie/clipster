import SwiftUI

/// The main floating panel view anchored to the menu bar icon.
/// Contains a search field, pinned section, and history section.
struct ClipboardPanelView: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Text("Clipster")
                .font(.headline)
                .foregroundColor(.secondary)
                .padding()
        }
        .frame(width: 380, height: 520)
        .background(panelBackground)
    }

    private var panelBackground: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1))
            : Color(nsColor: NSColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1))
    }
}
