// GeneralSettingsView.swift — polling cadence and system integration.

import SwiftUI
import AppKit

struct GeneralSettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section {
                Picker("Check for updates", selection: $state.refreshInterval) {
                    ForEach(Store.refreshIntervalChoices, id: \.self) { interval in
                        Text(Formatting.interval(interval)).tag(interval)
                    }
                }
            } header: {
                Text("Refreshing")
            } footer: {
                Text("Roost also refreshes whenever you open the menu. \(ProviderRegistry.names(joinedBy: "and")) meter usage per hour, so a longer interval leaves more headroom for large watch lists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show pending review count in the menu bar", isOn: $state.showBadge)
                Toggle("Open at login", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                ))
            } header: {
                Text("Menu bar")
            }

            Section {
                LabeledContent("Watching") {
                    Text("\(state.watched.count) repositories across \(state.accounts.count) account\(state.accounts.count == 1 ? "" : "s")")
                }
                LabeledContent("Last checked") {
                    Text(Formatting.lastUpdated(state.lastRefresh))
                }
                LabeledContent("Version") {
                    Text(Self.sourceVersion)
                        .font(.system(.body, design: .monospaced))
                        // The one string anyone will be asked to quote in a bug
                        // report, so it is copyable rather than retypeable.
                        .textSelection(.enabled)
                }
            } header: {
                Text("Status")
            }
        }
        .formStyle(.grouped)
    }

    /// The commit this build came from, stamped into the bundle's Info.plist by
    /// build-app.sh. Roost has no release cadence and no App Store listing, so a
    /// marketing version would be a number nobody bumps and everybody misreads;
    /// the SHA says exactly which source built this binary. A `-dirty` suffix
    /// means the tree had uncommitted changes at build time.
    private static var sourceVersion: String {
        Bundle.main.infoDictionary?["RoostGitSHA"] as? String ?? "unknown"
    }
}
