import SwiftUI

/// A single clipboard entry row in the panel.
/// Layout: [type icon] [content preview] [source app] [timestamp]
struct ClipboardEntryRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    let colorScheme: ColorScheme
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var onPin: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSuppressApp: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Type icon
            typeIcon
                .frame(width: 20, height: 20)

            // Content preview
            Text(entry.preview)
                .font(entry.contentType == .code ? .system(size: 13, design: .monospaced) : Theme.primaryFont)
                .foregroundColor(Theme.primaryText(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            // Source app + timestamp
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.sourceApp)
                    .font(Theme.secondaryFont)
                    .foregroundColor(Theme.secondaryText(for: colorScheme))
                    .lineLimit(1)

                Text(relativeTimestamp)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.secondaryText(for: colorScheme).opacity(0.7))
            }
        }
        .padding(.horizontal, Theme.panelPadding + 4)
        .frame(height: Theme.rowHeight)
        .background(rowBackground)
        .cornerRadius(Theme.rowCornerRadius)
        .padding(.horizontal, colorScheme == .light ? Theme.panelPadding : 4)
        .padding(.vertical, colorScheme == .light ? 2 : 0)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            contextMenuItems
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Copy") { onCopy?() }
        Button("Paste") { onPaste?() }

        Divider()

        Button(entry.isPinned ? "Unpin  ⌘P" : "Pin  ⌘P") { onPin?() }
        Button("Transform…  Tab") { /* stub — Phase 1 */ }
            .disabled(true)

        Divider()

        if !entry.sourceApp.isEmpty && entry.sourceApp != "Unknown" {
            Button("Don't capture from \(entry.sourceApp)") { onSuppressApp?() }
                .disabled(true) // Requires IPC command not yet in clipsterd
            Divider()
        }

        Button("Delete", role: .destructive) { onDelete?() }
    }

    // MARK: - Type Icon

    @ViewBuilder
    private var typeIcon: some View {
        if entry.contentType.isSFSymbol {
            Image(systemName: entry.contentType.icon)
                .font(.system(size: Theme.iconSize))
                .foregroundColor(Theme.iconTint(for: colorScheme))
        } else {
            Text(entry.contentType.icon)
                .font(.system(size: Theme.iconSize, weight: .medium))
                .foregroundColor(Theme.iconTint(for: colorScheme))
        }
    }

    // MARK: - Row Background

    private var rowBackground: some View {
        Group {
            if isSelected {
                Theme.rowSelected(for: colorScheme)
            } else if isHovered {
                Theme.rowHover(for: colorScheme)
            } else if colorScheme == .light {
                Theme.cardBackground(for: colorScheme)
            } else {
                Color.clear
            }
        }
    }

    // MARK: - Relative Timestamp

    private var relativeTimestamp: String {
        let interval = Date().timeIntervalSince(entry.timestamp)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}
