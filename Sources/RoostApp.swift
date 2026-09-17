// RoostApp.swift — entry point. A menu bar (LSUIElement) SwiftUI app: no Dock
// icon, no app menu, one MenuBarExtra whose window is the whole UI.

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let state = AppState.shared
            state.startPolling()
            state.refresh()

            // First run: there is nowhere for the popover's content to come
            // from until an account exists, so go straight to the place that
            // fixes that rather than showing an empty menu and hoping.
            if state.accounts.isEmpty {
                try? await Task.sleep(for: .milliseconds(300))
                state.openSettings()
            }
        }
    }
}

@main
struct RoostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(state)
        } label: {
            // `bird.fill` is a real SF Symbol, so there is nothing to hand-draw:
            // the system glyph already adapts to the menu bar's tint, vibrancy,
            // and the Increase Contrast setting, and it matches the app icon
            // (icon/draw-icon.swift renders the same symbol).
            MenuBarLabel(
                count: state.showBadge ? state.totalReviewRequests : 0,
                hasFailure: state.totalFailingChecks > 0
            )
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar item itself. Kept minimal on purpose: a glyph, and a number
/// only when there is actually something waiting on the user.
private struct MenuBarLabel: View {
    let count: Int
    let hasFailure: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: hasFailure ? "bird.fill" : "bird")
            if count > 0 {
                Text("\(count)").font(.system(.body, design: .default).monospacedDigit())
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = ["Roost"]
        if count > 0 { parts.append(Formatting.count(count, "review") + " waiting") }
        if hasFailure { parts.append("checks failing") }
        return parts.joined(separator: ", ")
    }
}
