import SwiftUI

/// Centralized color and style definitions for the Clipster panel.
/// All values are derived from the design mockups (dark + light variants).
enum Theme {
    // MARK: - Panel

    static func panelBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1)) // #1E1E1E
            : Color(nsColor: NSColor(red: 0.961, green: 0.961, blue: 0.961, alpha: 1)) // #F5F5F5
    }

    // MARK: - Search Field

    static func searchFieldBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: NSColor(red: 0.176, green: 0.176, blue: 0.176, alpha: 1)) // #2D2D2D
            : Color.white
    }

    static func searchFieldBorder(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: NSColor(red: 0.227, green: 0.227, blue: 0.227, alpha: 1)) // #3A3A3A
            : Color(nsColor: NSColor(red: 0.290, green: 0.565, blue: 0.851, alpha: 1)) // #4A90D9
    }

    // MARK: - Section Headers

    static func sectionHeaderColor(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: NSColor(red: 0.510, green: 0.510, blue: 0.510, alpha: 1)) // #828282
            : Color(nsColor: NSColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1)) // #8E8E93
    }

    // MARK: - Entry Rows

    static func primaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: NSColor(red: 0.831, green: 0.831, blue: 0.831, alpha: 1)) // #D4D4D4
            : Color(nsColor: NSColor(red: 0.114, green: 0.114, blue: 0.122, alpha: 1)) // #1D1D1F
    }

    static func secondaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: NSColor(red: 0.420, green: 0.420, blue: 0.420, alpha: 1)) // #6B6B6B
            : Color(nsColor: NSColor(red: 0.667, green: 0.667, blue: 0.667, alpha: 1)) // #AAAAAA
    }

    static func iconTint(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: NSColor(red: 0.600, green: 0.600, blue: 0.600, alpha: 1)) // #999999
            : Color(nsColor: NSColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1)) // #8E8E93
    }

    static func rowHover(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: NSColor(red: 0.200, green: 0.200, blue: 0.200, alpha: 1)) // #333333
            : Color(nsColor: NSColor(red: 0.922, green: 0.922, blue: 0.922, alpha: 1)) // #EBEBEB
    }

    static func rowSelected(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.accentColor.opacity(0.3)
            : Color.accentColor.opacity(0.15)
    }

    static func cardBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.clear // Dark mode: no card, rows sit on panel background
            : Color.white  // Light mode: white card
    }

    static func separator(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: NSColor(red: 0.227, green: 0.227, blue: 0.227, alpha: 1)) // #3A3A3A
            : Color(nsColor: NSColor(red: 0.847, green: 0.847, blue: 0.847, alpha: 1)) // #D8D8D8
    }

    // MARK: - Dimensions

    static let panelWidth: CGFloat = 380
    static let panelHeight: CGFloat = 520
    static let panelPadding: CGFloat = 12
    static let searchFieldHeight: CGFloat = 36
    static let searchFieldCornerRadius: CGFloat = 7
    static let rowHeight: CGFloat = 42
    static let rowCornerRadius: CGFloat = 6
    static let cardCornerRadius: CGFloat = 8
    static let sectionHeaderFont: Font = .system(size: 11, weight: .semibold)
    static let primaryFont: Font = .system(size: 13)
    static let secondaryFont: Font = .system(size: 11)
    static let iconSize: CGFloat = 16
}
