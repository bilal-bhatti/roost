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
                Text("Roost also refreshes whenever you open the menu. Both GitHub and GitLab meter usage per hour, so a longer interval leaves more headroom for large watch lists.")
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
                    Text(Self.version)
                }
            } header: {
                Text("Status")
            }
        }
        .formStyle(.grouped)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
