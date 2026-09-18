// MenuContentView.swift — the popover behind the menu bar icon.
//
// Three fixed zones, top to bottom: a summary header with the refresh control,
// the scrolling list of watched repos grouped by account, and the actions bar.
// Everything in the middle scrolls; the header and footer never move, so the
// controls stay where the pointer expects them regardless of how many repos are
// being watched.

import SwiftUI
import AppKit

struct MenuContentView: View {
    @EnvironmentObject var state: AppState

    /// Re-renders the relative "Updated 4 minutes ago" line. The timestamp
    /// itself doesn't change, so nothing else would invalidate this view and
    /// the label would otherwise go stale while the popover sits open.
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    /// Measured height of the repo list, so the scroll view can be given a real
    /// height instead of a cap it can satisfy with zero.
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: Metrics.popoverWidth)
        .onAppear {
            // The popover has no other way to report what it decided to draw,
            // and "the list is blank" has several possible causes that look
            // identical from outside: no accounts, an empty watch list, a
            // watch entry whose account id matches nothing, or a list that
            // rendered at zero height.
            let perAccount = state.accounts
                .map { "\($0.displayName)=\(state.repos(for: $0).count)" }
                .joined(separator: " ")
            Log.ui.notice("""
                Popover: accounts=\(state.accounts.count, privacy: .public) \
                watched=\(state.watched.count, privacy: .public) \
                perAccount=[\(perAccount, privacy: .public)] \
                frameHeight=\(listFrameHeight, privacy: .public) \
                measured=\(listHeight, privacy: .public)
                """)
            state.refresh()
        }
        .onReceive(clock) { now = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.rowSpacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(state.summary)
                    .font(.headline)
                    .lineLimit(1)
                Text(Formatting.lastUpdated(state.lastRefresh))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // `now` is unused in the string but ties the label to the
                    // clock so it re-renders every 30 seconds.
                    .id(now)
            }
            Spacer(minLength: 0)
            refreshControl
        }
        .padding(.horizontal, Metrics.contentInset)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var refreshControl: some View {
        if state.isRefreshing {
            // The system spinner, not a custom animation: it already honours
            // Reduce Motion and looks like every other macOS progress control.
            ProgressView()
                .controlSize(.small)
                .frame(width: 20, height: 20)
        } else {
            Button {
                state.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body)
            }
            .buttonStyle(.borderless)
            .frame(width: 20, height: 20)
            .disabled(state.watched.isEmpty)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh now")
            .accessibilityLabel("Refresh now")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if state.accounts.isEmpty {
            emptyState(
                title: "No accounts yet",
                systemImage: "person.crop.circle.badge.plus",
                message: "Add a \(ProviderRegistry.names(joinedBy: "or")) account to start watching repositories.",
                actionTitle: "Add an Account…",
                tab: .accounts
            )
        } else if state.watched.isEmpty {
            emptyState(
                title: "No repositories watched",
                systemImage: "checklist",
                message: "Choose the repositories you want to keep an eye on.",
                actionTitle: "Pick Repositories…",
                tab: .repositories
            )
        } else {
            ScrollView(.vertical) {
                // A plain VStack, not a LazyVStack. The measurement below
                // depends on the rows existing; a lazy stack asked for zero
                // height builds no children, reports zero, and stays zero.
                // A menu capped at a few dozen rows has nothing to gain from
                // laziness anyway.
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    ForEach(state.accounts) { account in
                        accountSection(account)
                    }
                }
                .padding(.vertical, 6)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            // An explicit height, not just a cap. A MenuBarExtra window sizes
            // itself to its content, so it proposes no height downward; a
            // ScrollView has no intrinsic height of its own, and the two
            // together resolve to nothing at all — the header and footer draw
            // and the list silently vanishes. Measuring the content and
            // clamping it is what gives the scroll view something to be.
            .frame(height: listFrameHeight)
            .onPreferenceChange(ListHeightKey.self) { height in
                Log.ui.notice("List measured at \(height, privacy: .public)pt")
                listHeight = height
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Height to give the scroll view: the measured content, capped.
    ///
    /// Falls back to an estimate from the row count until the first measurement
    /// arrives. Without that the list would be one point tall for a layout pass
    /// — and if the preference never fired at all, permanently invisible, which
    /// is a bad way for a menu to fail.
    private var listFrameHeight: CGFloat {
        let estimate = CGFloat(state.watched.count) * 44
            + CGFloat(state.accounts.count > 1 ? state.accounts.count * 24 : 0)
            + 12
        let natural = listHeight > 0 ? listHeight : estimate
        return min(max(natural, 44), Metrics.listMaxHeight)
    }

    @ViewBuilder
    private func accountSection(_ account: Account) -> some View {
        let repos = state.repos(for: account)
        let error = state.accountErrors[account.id]

        if !repos.isEmpty || error != nil {
            // With a single account the heading is noise: the whole popover is
            // that account.
            if state.accounts.count > 1 {
                SectionHeader(title: account.displayName, detail: account.subtitle)
            }
            if let error {
                AccountErrorRow(account: account, message: error) {
                    // An account-level failure is almost always the token, so
                    // land on the pane that holds it.
                    state.openSettings(tab: .accounts)
                }
            }
            ForEach(repos) { repo in
                RepoRow(
                    repo: repo,
                    highlights: state.highlights(for: repo),
                    lexicon: account.lexicon
                ) {
                    state.open(repo)
                }
            }
        }
    }

    private func emptyState(
        title: String,
        systemImage: String,
        message: String,
        actionTitle: String,
        tab: AppState.SettingsTab
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button(actionTitle) { state.openSettings(tab: tab) }
        }
        .frame(height: 190)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 1) {
            ActionRow(title: "Settings…", systemImage: "gearshape", shortcut: ",") {
                state.openSettings()
            }
            ActionRow(title: "Quit Roost", systemImage: "power", shortcut: "q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Pieces

/// Carries the repo list's natural height up to the scroll view that contains
/// it. `max` rather than a sum: there is one reporter, and taking the larger
/// value keeps a transient zero from a mid-layout pass out of the result.
private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Group heading, shown only when more than one account is configured.
private struct SectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
            if !detail.isEmpty, detail != title {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Metrics.contentInset)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// An account-wide failure: an expired token, an unreachable host, a rate
/// limit. Tapping goes to the place where it can be fixed.
private struct AccountErrorRow: View {
    let account: Account
    let message: String
    let action: () -> Void

    var body: some View {
        RowButton(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.rowSpacing) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body)
                    .frame(width: 16)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.displayName)
                        .font(.body)
                        .rowText(.primary)
                    Text(message)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .rowText(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(account.displayName): \(message). Open Settings.")
        .accessibilityAddTraits(.isButton)
    }
}
