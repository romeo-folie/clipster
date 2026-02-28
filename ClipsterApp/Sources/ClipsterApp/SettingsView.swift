import SwiftUI

/// Settings window — full PRD §7.8 spec.
/// Persists to UserDefaults; values synced to clipsterd config on save.
struct SettingsView: View {
    @StateObject private var settings = SettingsViewModel()

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings)
                .tabItem { Label("General", systemImage: "gear") }

            AppearanceSettingsTab(settings: settings)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            PrivacySettingsTab(settings: settings)
                .tabItem { Label("Privacy", systemImage: "lock.shield") }

            AdvancedSettingsTab(settings: settings)
                .tabItem { Label("Advanced", systemImage: "wrench") }
        }
        .frame(width: 480, height: 360)
        .padding()
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @ObservedObject var settings: SettingsViewModel

    var body: some View {
        Form {
            Picker("History entry limit", selection: $settings.entryLimit) {
                Text("Compact (100)").tag(100)
                Text("Standard (500)").tag(500)
                Text("Extended (2000)").tag(2000)
                Text("No limit").tag(0)
            }

            Picker("Database size cap", selection: $settings.dbSizeCap) {
                Text("100 MB").tag(100)
                Text("250 MB").tag(250)
                Text("500 MB").tag(500)
                Text("1 GB").tag(1000)
            }

            HStack {
                Text("Global shortcut")
                Spacer()
                Text(settings.shortcutDisplay)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
                // Full shortcut capture deferred — would need KeyboardShortcuts or custom NSView
            }

            Toggle("Launch at login", isOn: $settings.launchAtLogin)
        }
        .padding()
    }
}

// MARK: - Appearance Tab

struct AppearanceSettingsTab: View {
    @ObservedObject var settings: SettingsViewModel

    var body: some View {
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                Text("Auto (System)").tag(AppearanceMode.auto)
                Text("Light").tag(AppearanceMode.light)
                Text("Dark").tag(AppearanceMode.dark)
            }
            .pickerStyle(.segmented)

            Text("When set to Auto, Clipster follows your system appearance.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

// MARK: - Privacy Tab

struct PrivacySettingsTab: View {
    @ObservedObject var settings: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Privacy Suppress List")
                .font(.headline)
            Text("Clipboard content from these apps will not be captured.")
                .font(.caption)
                .foregroundColor(.secondary)

            List {
                ForEach(settings.suppressedApps, id: \.self) { app in
                    HStack {
                        Text(app)
                        Spacer()
                        Button {
                            settings.removeSuppressedApp(app)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 120)

            HStack {
                TextField("Bundle ID or app name", text: $settings.newSuppressApp)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    settings.addSuppressedApp()
                }
                .disabled(settings.newSuppressApp.isEmpty)
            }
        }
        .padding()
    }
}

// MARK: - Advanced Tab

struct AdvancedSettingsTab: View {
    @ObservedObject var settings: SettingsViewModel
    @State private var showClearConfirmation = false

    var body: some View {
        Form {
            Section {
                Button("Clear History…") {
                    showClearConfirmation = true
                }
                .alert("Clear Clipboard History?", isPresented: $showClearConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Clear", role: .destructive) {
                        settings.clearHistory()
                    }
                } message: {
                    Text("This will permanently delete all clipboard history. Pinned items will be kept.")
                }
            }

            Section {
                HStack {
                    Text("CLI")
                    Spacer()
                    if settings.cliInstalled {
                        Text("Installed")
                            .foregroundColor(.green)
                        Button("Uninstall") {
                            settings.uninstallCLI()
                        }
                    } else {
                        Text("Not installed")
                            .foregroundColor(.secondary)
                        Button("Install") {
                            settings.installCLI()
                        }
                    }
                }
            }
        }
        .padding()
    }
}
