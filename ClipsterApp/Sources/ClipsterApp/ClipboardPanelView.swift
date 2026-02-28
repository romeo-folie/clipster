import SwiftUI

/// The main floating panel view anchored to the menu bar icon.
/// Contains a search field, pinned section, and history section.
struct ClipboardPanelView: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var viewModel: ClipboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
                .background(Theme.separator(for: colorScheme))

            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    if !viewModel.filteredPinned.isEmpty {
                        sectionHeader("PINNED")
                        ForEach(viewModel.filteredPinned) { entry in
                            ClipboardEntryRow(
                                entry: entry,
                                isSelected: viewModel.selectedID == entry.id,
                                colorScheme: colorScheme
                            )
                            .onTapGesture { viewModel.selectedID = entry.id }
                        }
                    }

                    if !viewModel.filteredHistory.isEmpty {
                        if !viewModel.filteredPinned.isEmpty {
                            Divider()
                                .background(Theme.separator(for: colorScheme))
                                .padding(.vertical, 4)
                        }
                        sectionHeader("HISTORY")
                        ForEach(viewModel.filteredHistory) { entry in
                            ClipboardEntryRow(
                                entry: entry,
                                isSelected: viewModel.selectedID == entry.id,
                                colorScheme: colorScheme
                            )
                            .onTapGesture { viewModel.selectedID = entry.id }
                        }
                    }

                    // Empty states
                    if viewModel.filteredPinned.isEmpty && viewModel.filteredHistory.isEmpty {
                        emptyState
                    }
                }
                .padding(.bottom, Theme.panelPadding)
            }
        }
        .frame(width: Theme.panelWidth, height: Theme.panelHeight)
        .background(Theme.panelBackground(for: colorScheme))
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.secondaryText(for: colorScheme))
                .font(.system(size: 14))

            TextField("Search…", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(Theme.primaryFont)
                .foregroundColor(Theme.primaryText(for: colorScheme))
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.searchFieldHeight)
        .background(Theme.searchFieldBackground(for: colorScheme))
        .cornerRadius(Theme.searchFieldCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.searchFieldCornerRadius)
                .stroke(Theme.searchFieldBorder(for: colorScheme), lineWidth: 1)
        )
        .padding(.horizontal, Theme.panelPadding)
        .padding(.top, Theme.panelPadding)
        .padding(.bottom, 8)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(Theme.sectionHeaderFont)
                .foregroundColor(Theme.sectionHeaderColor(for: colorScheme))
                .tracking(0.8)
            Spacer()
        }
        .padding(.horizontal, Theme.panelPadding + 4)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 60)
            if viewModel.searchQuery.isEmpty {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 36))
                    .foregroundColor(Theme.secondaryText(for: colorScheme))
                Text("Your clipboard history will appear here")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.secondaryText(for: colorScheme))
                Text("Copy anything to get started. Access Clipster with ⌘⇧V")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText(for: colorScheme).opacity(0.7))
            } else {
                Text("No matches for \"\(viewModel.searchQuery)\"")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.secondaryText(for: colorScheme))
                Button("Clear search") {
                    viewModel.searchQuery = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .font(.system(size: 12))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
