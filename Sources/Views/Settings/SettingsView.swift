// SettingsView.swift — the settings window.
//
// A TabView with toolbar-style tabs is the macOS settings idiom, so it is what
// Roost uses: three panes, each a single Form, no custom chrome. The window
// itself is a plain titled NSWindow owned by AppState (see openSettings) since
// an LSUIElement agent has no app menu to hang a Settings scene off.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        // Selection is bound to AppState so the popover can open the pane that
        // answers whatever it was complaining about.
        TabView(selection: $state.settingsTab) {
            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "person.2") }
                .tag(AppState.SettingsTab.accounts)
            RepositoriesSettingsView()
                .tabItem { Label("Repositories", systemImage: "list.bullet.rectangle") }
                .tag(AppState.SettingsTab.repositories)
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(AppState.SettingsTab.general)
        }
        .frame(width: Metrics.settingsSize.width, height: Metrics.settingsSize.height)
    }
}
