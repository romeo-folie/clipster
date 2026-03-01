import AppKit
import SwiftUI

/// The main floating panel view anchored to the menu bar icon.
/// Contains a search field, pinned section, and history section.
struct ClipboardPanelView: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var viewModel: ClipboardViewModel
    var onPaste: ((ClipboardEntry) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
                .background(Theme.separator(for: colorScheme))

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    if !viewModel.filteredPinned.isEmpty {
                        sectionHeader("PINNED")
                        ForEach(viewModel.filteredPinned) { entry in
                            // "p-" prefix ensures pinned rows have a distinct SwiftUI
                            // identity from the same entry in the history section.
                            // Without this, SwiftUI may reuse the history row view
                            // (where isPinned=false was captured) when an item is
                            // pinned, resulting in a stale "Pin" label in the context menu.
                            entryRow(for: entry).id("p-\(entry.id)")
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
                            entryRow(for: entry).id("h-\(entry.id)")
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
        .overlay(alignment: .bottom) {
            if viewModel.showTransformPanel, let entry = selectedEntry {
                TransformPanelView(
                    entry: entry,
                    onApply: { transformedText in
                        viewModel.showTransformPanel = false
                        onPaste?(ClipboardEntry(
                            id: entry.id, contentType: entry.contentType,
                            content: transformedText, preview: transformedText,
                            sourceApp: entry.sourceApp, timestamp: entry.timestamp,
                            isPinned: entry.isPinned
                        ))
                    },
                    onCancel: { viewModel.showTransformPanel = false }
                )
                .frame(height: Theme.panelHeight * 0.55)
                .transition(.move(edge: .bottom))
                .animation(.easeInOut(duration: 0.2), value: viewModel.showTransformPanel)
            }
        }
    }

    private var selectedEntry: ClipboardEntry? {
        guard let id = viewModel.selectedID else { return nil }
        let all = viewModel.filteredPinned + viewModel.filteredHistory
        return all.first(where: { $0.id == id })
    }

    // MARK: - Entry Row Factory

    private func entryRow(for entry: ClipboardEntry) -> some View {
        ClipboardEntryRow(
            entry: entry,
            isSelected: viewModel.selectedID == entry.id,
            onCopy: {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(entry.content, forType: .string)
            },
            onPaste: { onPaste?(entry) },
            onPin: { viewModel.togglePin(id: entry.id) },
            onTransform: {
                viewModel.selectedID = entry.id
                viewModel.showTransformPanel = true
            },
            onDelete: { viewModel.deleteEntry(id: entry.id) },
            onSuppressApp: { viewModel.suppressApp(bundleOrName: entry.sourceApp) }
        )
        .onTapGesture { viewModel.selectedID = entry.id }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.secondaryText(for: colorScheme))
                .font(.system(size: 14))

            FocusedTextField(
                text: $viewModel.searchQuery,
                placeholder: "Search…"
            )
            .frame(height: 20)
            .foregroundColor(Theme.primaryText(for: colorScheme))

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.secondaryText(for: colorScheme))
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
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
        .animation(.easeInOut(duration: 0.15), value: viewModel.searchQuery.isEmpty)
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
