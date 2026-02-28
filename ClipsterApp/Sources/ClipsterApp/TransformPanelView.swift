import AppKit
import ClipsterCore
import SwiftUI

/// Transform panel — slides up as a bottom-sheet overlay within the floating panel.
/// PRD §7.4: live preview on hover, Enter applies + pastes, Escape cancels.
/// Transforms execute via IPC "transform" command to preserve sole-write-owner invariant.
struct TransformPanelView: View {
    @Environment(\.colorScheme) var colorScheme

    let entry: ClipboardEntry
    let onApply: (String) -> Void  // Called with transformed text
    let onCancel: () -> Void

    @State private var hoveredTransform: String?
    @State private var selectedIndex = 0
    @State private var previewText: String = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let transforms: [(name: String, label: String)] = [
        ("uppercase", "UPPERCASE"),
        ("lowercase", "lowercase"),
        ("title_case", "Title Case"),
        ("trim", "Trim whitespace"),
        ("snake_case", "snake_case"),
        ("camel_case", "camelCase"),
        ("encode_url", "URL Encode"),
        ("decode_url", "URL Decode"),
        ("encode_base64", "Base64 Encode"),
        ("decode_base64", "Base64 Decode"),
        ("strip_html", "Strip HTML"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Live preview pane
            previewPane

            Divider()
                .background(Theme.separator(for: colorScheme))

            // Transform list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(transforms.enumerated()), id: \.offset) { index, transform in
                        transformRow(transform: transform, index: index)
                    }
                }
            }
        }
        .background(Theme.panelBackground(for: colorScheme))
        .onAppear {
            previewText = entry.content
        }
    }

    // MARK: - Preview Pane

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                    Spacer()
                    Button {
                        errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
            }

            Text(previewText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(Theme.primaryText(for: colorScheme))
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.panelPadding)
        .frame(minHeight: 80)
    }

    // MARK: - Transform Row

    private func transformRow(transform: (name: String, label: String), index: Int) -> some View {
        HStack {
            if index == selectedIndex {
                Text(">")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.accentColor)
            }
            Text(transform.label)
                .font(Theme.primaryFont)
                .foregroundColor(Theme.primaryText(for: colorScheme))
            Spacer()
        }
        .padding(.horizontal, Theme.panelPadding + 4)
        .frame(height: 32)
        .background(rowBackground(index: index))
        .cornerRadius(Theme.rowCornerRadius)
        .padding(.horizontal, 4)
        .onHover { hovering in
            if hovering {
                hoveredTransform = transform.name
                selectedIndex = index
                fetchPreview(transformName: transform.name)
            } else if hoveredTransform == transform.name {
                hoveredTransform = nil
            }
        }
        .onTapGesture {
            selectedIndex = index
            applyTransform(transformName: transform.name)
        }
    }

    private func rowBackground(index: Int) -> some View {
        Group {
            if index == selectedIndex {
                Theme.rowSelected(for: colorScheme)
            } else if hoveredTransform == transforms[index].name {
                Theme.rowHover(for: colorScheme)
            } else {
                Color.clear
            }
        }
    }

    // MARK: - IPC Transform Calls

    private func fetchPreview(transformName: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let response = try IPCClient.send(
                    "transform",
                    params: IPCParams(entryID: entry.id, transform: transformName)
                )
                DispatchQueue.main.async {
                    if response.ok, case .transform(let result)? = response.data {
                        previewText = result
                        errorMessage = nil
                    } else if let err = response.error {
                        previewText = entry.content
                        errorMessage = err
                    }
                }
            } catch {
                // IPC failed — fall back to local transform.
                DispatchQueue.main.async {
                    do {
                        previewText = try Transform.apply(transformName, to: entry.content)
                        errorMessage = nil
                    } catch {
                        previewText = entry.content
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func applyTransform(transformName: String) {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let response = try IPCClient.send(
                    "transform",
                    params: IPCParams(entryID: entry.id, transform: transformName)
                )
                DispatchQueue.main.async {
                    isLoading = false
                    if response.ok, case .transform(let result)? = response.data {
                        onApply(result)
                    } else if let err = response.error {
                        errorMessage = err
                    }
                }
            } catch {
                // Fallback to local transform.
                DispatchQueue.main.async {
                    isLoading = false
                    do {
                        let result = try Transform.apply(transformName, to: entry.content)
                        onApply(result)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}

// MARK: - IPCParams extension for transform

extension IPCParams {
    init(entryID: String, transform: String) {
        self.init(limit: nil, offset: nil, entryID: entryID, transform: transform)
    }
}
