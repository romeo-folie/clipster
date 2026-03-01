import SwiftUI

/// A single clipboard entry row in the panel.
/// Layout: [type icon] [content preview] [source app] [timestamp]
struct ClipboardEntryRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    // Read colorScheme from the environment so it always reflects the live
    // system appearance — passing it as a parameter can leave it stale when
    // NSApp.appearance is changed while the panel is open.
    @Environment(\.colorScheme) private var colorScheme
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var onPin: (() -> Void)?
    var onTransform: (() -> Void)?
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
        Button("Transform…  Tab") { onTransform?() }

        Divider()

        if !entry.sourceApp.isEmpty && entry.sourceApp != "Unknown" {
            Button("Don't capture from \(entry.sourceApp)") { onSuppressApp?() }
            Divider()
        }

        Button("Delete", role: .destructive) { onDelete?() }
    }

    // MARK: - Type Icon

    @ViewBuilder
    private var typeIcon: some View {
        if entry.contentType == .richText {
            // Rich text: styled A with RTF badge
            ZStack(alignment: .bottomTrailing) {
                Text("A")
                    .font(.system(size: Theme.iconSize, weight: .bold))
                    .foregroundColor(Theme.iconTint(for: colorScheme))
                Text("RTF")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 2)
                    .background(Color.orange)
                    .cornerRadius(2)
                    .offset(x: 2, y: 2)
            }
        } else if entry.contentType == .colour {
            // Colour: filled square tinted with the detected colour
            RoundedRectangle(cornerRadius: 3)
                .fill(parseColour(from: entry.content))
                .frame(width: Theme.iconSize, height: Theme.iconSize)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Theme.iconTint(for: colorScheme), lineWidth: 0.5)
                )
        } else if entry.contentType.isSFSymbol {
            Image(systemName: entry.contentType.icon)
                .font(.system(size: Theme.iconSize))
                .foregroundColor(Theme.iconTint(for: colorScheme))
        } else {
            Text(entry.contentType.icon)
                .font(.system(size: Theme.iconSize, weight: .medium))
                .foregroundColor(Theme.iconTint(for: colorScheme))
        }
    }

    /// Parse a hex colour string (#RRGGBB or #RGB) into a SwiftUI Color.
    private func parseColour(from text: String) -> Color {
        let hex = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
        guard hex.count == 6 || hex.count == 3 else { return .gray }
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        if hex.count == 6 {
            return Color(
                red: Double((rgb >> 16) & 0xFF) / 255,
                green: Double((rgb >> 8) & 0xFF) / 255,
                blue: Double(rgb & 0xFF) / 255
            )
        } else {
            let r = Double((rgb >> 8) & 0xF) / 15
            let g = Double((rgb >> 4) & 0xF) / 15
            let b = Double(rgb & 0xF) / 15
            return Color(red: r, green: g, blue: b)
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
        guard interval >= 0 else { return "now" }
        if interval < 60    { return "now" }
        if interval < 3600  { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}
