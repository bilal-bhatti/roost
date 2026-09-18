// RepositoriesSettingsView.swift — the repo picker.
//
// Lists everything the selected account's token can see and lets the user tick
// what to watch. The listing is fetched once per account per launch (AppState
// caches it) because paging a large instance is slow and the set barely changes.
//
// The list is split in two — what you watch, then what you could — and that
// split is the whole point of this pane's layout. A single alphabetical list of
// 200 repositories with three ticks scattered through it answers "what does
// Roost watch?" only by scrolling the entire thing, and that is the question
// somebody opening this pane is most often asking. Ticking a row moves it
// between the two sections, so the action explains itself the first time it is
// used. The scope switches that used to sit in a strip along the bottom now live
// in one Filters menu, because they change what the list *contains* and belong
// next to the counts that say so.

import SwiftUI

struct RepositoriesSettingsView: View {
    @EnvironmentObject private var state: AppState

    @State private var accountID: UUID?
    @State private var repos: [RemoteRepo] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var filter = ""
    @State private var includeArchived = false
    /// Restrict the list to the account's resource owner. On by default: the
    /// unscoped listing is mostly public repositories that have nothing to do
    /// with this account, and it looks identical for every account on the host.
    @State private var ownerOnly = true
    @State private var confirmingRemoveAll = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            statusBar
        }
        .onAppear { if accountID == nil { accountID = state.accounts.first?.id } }
        .task(id: accountID) { await load(reload: false) }
    }

    private var account: Account? { accountID.flatMap(state.account(id:)) }

    /// The selected account's provider vocabulary. GitHub lists repositories
    /// owned by an owner; GitLab lists projects under a namespace, and this pane
    /// says whichever applies rather than splitting the difference.
    private var lexicon: ProviderLexicon { (account?.kind ?? .github).lexicon }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            // A visible label, even with one account. An unlabelled popup that
            // is also disabled reads as something broken rather than as the
            // single account it is stating.
            Text("Account")
                .foregroundStyle(.secondary)
            Picker("Account", selection: $accountID) {
                ForEach(state.accounts) { account in
                    // Name plus scope: two accounts can share a name, and what
                    // the token reaches is what decides this pane's contents.
                    Text(account.pickerTitle).tag(Optional(account.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .disabled(state.accounts.count < 2)

            SearchField(prompt: "Filter \(lexicon.repoNounPlural)", text: $filter)

            Button {
                Task { await load(reload: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(account == nil || loading)
            .help("Reload the list from the server")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if state.accounts.isEmpty {
            ContentUnavailableView {
                Label("No accounts yet", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("Add an account on the Accounts tab first.")
            } actions: {
                Button("Open Accounts") { state.settingsTab = .accounts }
            }
        } else if loading && repos.isEmpty {
            // Indeterminate: neither provider reports total pages up front, so
            // a determinate bar would be a lie.
            ProgressView("Loading \(lexicon.repoNounPlural)…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't load \(lexicon.repoNounPlural)", systemImage: "exclamationmark.triangle")
            } description: {
                // Selectable so the exact server wording can be copied into a
                // bug report rather than retyped from a screenshot.
                Text(errorMessage)
                    .textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await load(reload: true) } }
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                if watching.isEmpty {
                    Text(watchedTotal == 0
                         ? "Nothing watched yet. Tick a \(lexicon.repoNoun) below to add it."
                         : "No watched \(lexicon.repoNoun) matches this filter.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(watching) { entry in
                        RepoPickRow(entry: entry, isOn: watchBinding(entry.repo))
                    }
                }
            } header: {
                // The filtered count, not the total: a header reading "12" above
                // two rows is a header arguing with the list under it. The
                // untouched total is in the status bar, where it belongs.
                sectionHeader(title: "Watching", count: watching.count) {
                    if hasUnlistedWatches {
                        InfoButton(title: "Watched, but not in the listing", message: missingRepoHint)
                    }
                    Spacer()
                    if watchedTotal > 0 {
                        Button("Remove All") { confirmingRemoveAll = true }
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                }
            }

            Section {
                if available.isEmpty {
                    Text(filter.isEmpty ? "Nothing else to add." : "No matches.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(available) { entry in
                        RepoPickRow(entry: entry, isOn: watchBinding(entry.repo))
                    }
                }
            } header: {
                sectionHeader(title: "Available", count: available.count) { Spacer() }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .confirmationDialog(
            "Stop watching all \(lexicon.repoCount(watchedTotal))?",
            isPresented: $confirmingRemoveAll
        ) {
            Button("Stop Watching", role: .destructive) {
                if let account { state.unwatchAll(in: account) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They stay on \(account?.host ?? "the server"). Roost just stops showing them.")
        }
    }

    private func sectionHeader<Accessory: View>(
        title: String,
        count: Int,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            accessory()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let account {
                Text("\(watchedTotal) watched · \(available.count) of \(repos.count) shown")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Watched through \(account.displayName)")
            }
            Spacer()
            filtersMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var filtersMenu: some View {
        Menu {
            if let scopeName {
                Toggle("Only \(scopeName)", isOn: $ownerOnly)
                    .help("This token can only read private \(lexicon.repoNounPlural) under the \(lexicon.namespaceNoun) \(scopeName). Everything else the server lists is public, and readable by any token.")
            }
            Toggle("Show archived", isOn: $includeArchived)
        } label: {
            // The symbol fills in when a filter is on, because a repository
            // hidden by a filter and one the token can't see look identical
            // from here — and only one of them is the user's own doing.
            Label("Filters", systemImage: filtersAreDefault
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .disabled(account == nil)
    }

    private var filtersAreDefault: Bool { ownerOnly && !includeArchived }

    /// The one namespace this account's token is scoped to, if it is scoped to
    /// one at all. Comes from the credential's own scope, so a classic GitHub
    /// token and a GitLab personal access token correctly offer no such filter.
    private var scopeName: String? { account?.scope.targetName }

    // MARK: - Data

    private var watchedTotal: Int {
        guard let account else { return 0 }
        return state.repos(for: account).count
    }

    private var watching: [RepoEntry] {
        guard let account else { return [] }
        // Same repo can appear once per page boundary in a pathological listing;
        // keep the first rather than trapping on a duplicate key.
        let listed = Dictionary(repos.map { ($0.fullName, $0) }, uniquingKeysWith: { first, _ in first })
        return state.repos(for: account)
            .sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
            .map { watched in
                if let match = listed[watched.fullName] {
                    return RepoEntry(repo: match, isListed: true)
                }
                return RepoEntry(
                    repo: RemoteRepo(namespace: watched.namespace, name: watched.name,
                                     isPrivate: false, isArchived: false),
                    isListed: false
                )
            }
            // Only the text filter applies here. Scope switches must never hide
            // a ticked box: an archived repo you already watch stays visible
            // whatever "Show archived" says.
            .filter { matches(query, $0.repo) }
    }

    private var available: [RepoEntry] {
        guard let account else { return [] }
        return repos
            .filter { repo in
                guard !state.isWatching(repo, in: account) else { return false }
                // Every token can read every public repository on the host,
                // regardless of scope, so the raw listing spans owners this
                // account has nothing to do with — and two accounts on the same
                // host come back looking nearly identical. Scoping to the
                // resource owner is what makes each account's list mean
                // something: it is the only owner whose private repositories
                // this token can actually read.
                if let scope = scopeFilter,
                   repo.namespace.caseInsensitiveCompare(scope) != .orderedSame {
                    return false
                }
                if repo.isArchived, !includeArchived { return false }
                return matches(query, repo)
            }
            .map { RepoEntry(repo: $0, isListed: true) }
    }

    private var hasUnlistedWatches: Bool { watching.contains { !$0.isListed } }

    private var query: String { filter.trimmingCharacters(in: .whitespaces).lowercased() }

    private func matches(_ query: String, _ repo: RemoteRepo) -> Bool {
        query.isEmpty || repo.fullName.lowercased().contains(query)
    }

    /// Namespace to restrict the list to, or nil when showing everything. Nil
    /// wherever the credential is not scoped to one, where the listing the
    /// server returns is already the right set.
    private var scopeFilter: String? {
        ownerOnly ? scopeName : nil
    }

    /// Why a watched repo can be absent from the listing. Worth spelling out:
    /// the single-resource-owner rule is the most common reason a repo someone
    /// obviously has access to simply isn't there, and nothing in the GitHub UI
    /// says so at the point you'd notice.
    private var missingRepoHint: String {
        guard account?.kind == .github else {
            return "Rows marked with a ? are watched, but this token can't see them. They may have been renamed, deleted, or moved out of its reach."
        }
        return "Rows marked with a ? are watched, but this token can't see them.\n\nA fine-grained token only reaches private repositories owned by its one resource owner; everything else it sees is public. To watch a private repository under another user or organisation, add a second account with a token whose resource owner is that user or organisation."
    }

    private func watchBinding(_ repo: RemoteRepo) -> Binding<Bool> {
        Binding(
            get: { account.map { state.isWatching(repo, in: $0) } ?? false },
            set: { watching in
                guard let account else { return }
                state.setWatching(watching, repo: repo, in: account)
            }
        )
    }

    private func load(reload: Bool) async {
        guard let account else {
            repos = []
            return
        }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            repos = try await state.repositories(for: account, reload: reload)
            // Namespace spread is the tell for whether the server actually
            // scoped the listing to this token or just handed back everything
            // public.
            let namespaces = Set(repos.map { $0.namespace.lowercased() })
            Log.network.notice("Listing for \(account.subtitle, privacy: .public): \(repos.count, privacy: .public) repos across \(namespaces.count, privacy: .public) namespaces")
        } catch {
            // Cancellation means the tab closed or the account selection
            // changed while the fetch was in flight. Both are the user's doing,
            // so leave the view as it is instead of flashing a failure.
            guard !Log.isCancellation(error) else { return }
            repos = []
            errorMessage = Log.describe(error)
            Log.network.error("Repository listing failed for \(account.host, privacy: .public): \(Log.describe(error), privacy: .public)")
        }
    }
}

// MARK: - Row

/// One row of either section. `isListed` is false for a repo the user watches
/// that the server's listing doesn't contain — the token lost access, the repo
/// was renamed, or it fell outside the page cap. Those rows have to exist
/// somewhere or they'd be watched forever with no way to untick them, and
/// "Watching" is where they honestly belong.
private struct RepoEntry: Identifiable {
    let repo: RemoteRepo
    let isListed: Bool
    var id: String { repo.id }
}

/// One repository, ticked or not.
///
/// The checkbox is the whole row: the label fills the width and carries a
/// content shape, so the hit target is the line you are pointing at rather than
/// a 14pt square at its left edge. Missing that square and hitting nothing is
/// what made the old list feel like it had no action in it at all.
private struct RepoPickRow: View {
    let entry: RepoEntry
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 6) {
                Text(entry.repo.fullName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !entry.isListed {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .help("Watched, but not returned by the server for this token")
                }
                if entry.repo.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Private")
                }
                if entry.repo.isArchived {
                    Text("Archived")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(entry.repo.fullName)
    }
}
