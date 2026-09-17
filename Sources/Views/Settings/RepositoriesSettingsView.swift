// RepositoriesSettingsView.swift — the repo picker.
//
// Lists everything the selected account's token can see and lets the user tick
// what to watch. The listing is fetched once per account per launch (AppState
// caches it) because paging a large instance is slow and the set barely changes.

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

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("Account", selection: $accountID) {
                ForEach(state.accounts) { account in
                    // Name plus owner: two accounts can share a name, and the
                    // owner is what decides which repositories this pane lists.
                    Text(account.pickerTitle).tag(Optional(account.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            .disabled(state.accounts.count < 2)

            TextField("Filter", text: $filter, prompt: Text("Filter repositories"))
                .textFieldStyle(.roundedBorder)

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
            }
        } else if loading && repos.isEmpty {
            // Indeterminate: neither provider reports total pages up front, so
            // a determinate bar would be a lie.
            ProgressView("Loading repositories…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't load repositories", systemImage: "exclamationmark.triangle")
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
            // Repos the user already watches that aren't in the listing — the
            // token lost access, the repo was renamed, or it fell outside the
            // page cap. Without this section they'd be watched forever with no
            // way to untick them.
            if !orphans.isEmpty {
                Section("Watched but not in the listing") {
                    Text(missingRepoHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(orphans) { repo in
                        Toggle(isOn: watchBinding(repo)) {
                            HStack(spacing: 6) {
                                Text(repo.fullName)
                                Image(systemName: "questionmark.circle")
                                    .foregroundStyle(.secondary)
                                    .help("Not returned by the server for this token")
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            Section(sectionTitle) {
                ForEach(filtered) { repo in
                    Toggle(isOn: watchBinding(repo)) {
                        HStack(spacing: 6) {
                            Text(repo.fullName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if repo.isPrivate {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .help("Private")
                            }
                            if repo.isArchived {
                                Text("Archived")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                if filtered.isEmpty {
                    Text(filter.isEmpty ? "No repositories found." : "No matches.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let owner = account?.owner.trimmingCharacters(in: .whitespaces), !owner.isEmpty {
                Toggle("Only \(owner)", isOn: $ownerOnly)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("This token can only read private repositories owned by \(owner). Everything else the server lists is public, and readable by any token.")
            }
            Toggle("Show archived", isOn: $includeArchived)
                .toggleStyle(.checkbox)
                .controlSize(.small)
            Spacer()
            if let account {
                Text("\(state.repos(for: account).count) watched · \(filtered.count) of \(repos.count) shown")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Data

    private var filtered: [RemoteRepo] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let owner = ownerFilter
        return repos.filter { repo in
            // Every token can read every public repository on the host,
            // regardless of scope, so the raw listing spans owners this account
            // has nothing to do with — and two accounts on the same host come
            // back looking nearly identical. Scoping to the resource owner is
            // what makes each account's list mean something: it is the only
            // owner whose private repositories this token can actually read.
            if let owner,
               repo.owner.caseInsensitiveCompare(owner) != .orderedSame,
               !isWatched(repo) {
                return false
            }
            // An archived repo the user already watches stays visible, so the
            // filter can never hide a ticked box.
            if repo.isArchived, !includeArchived, !isWatched(repo) { return false }
            guard !query.isEmpty else { return true }
            return repo.fullName.lowercased().contains(query)
        }
    }

    /// Owner to restrict the list to, or nil when showing everything. Nil for
    /// GitLab and for accounts with no owner recorded, where the listing the
    /// server returns is already the right set.
    private var ownerFilter: String? {
        guard ownerOnly,
              let owner = account?.owner.trimmingCharacters(in: .whitespaces),
              !owner.isEmpty
        else { return nil }
        return owner
    }

    private var sectionTitle: String {
        if !filter.isEmpty { return "Matching “\(filter)”" }
        if let owner = ownerFilter { return "Owned by \(owner)" }
        return "Repositories"
    }

    /// Why a watched repo can be absent from the listing. Worth spelling out:
    /// the single-resource-owner rule is the most common reason a repo someone
    /// obviously has access to simply isn't there, and nothing in the GitHub UI
    /// says so at the point you'd notice.
    private var missingRepoHint: String {
        guard account?.kind == .github else {
            return "This token can't see these — they may have been renamed, deleted, or moved out of its reach."
        }
        return "This token can't see these. A fine-grained token only reaches private repositories owned by its one resource owner; everything else it sees is public. To watch a private repo under another user or organisation, add a second account here with a token whose resource owner is that user or organisation."
    }

    /// Watched entries with no match in the fetched listing.
    private var orphans: [RemoteRepo] {
        guard let account else { return [] }
        let listed = Set(repos.map(\.fullName))
        return state.repos(for: account)
            .filter { !listed.contains($0.fullName) }
            .map { RemoteRepo(owner: $0.owner, name: $0.name, isPrivate: false, isArchived: false) }
    }

    private func isWatched(_ repo: RemoteRepo) -> Bool {
        guard let account else { return false }
        return state.isWatching(repo, in: account)
    }

    private func watchBinding(_ repo: RemoteRepo) -> Binding<Bool> {
        Binding(
            get: { isWatched(repo) },
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
            // Owner spread is the tell for whether the server actually scoped
            // the listing to this token or just handed back everything public.
            let owners = Set(repos.map { $0.owner.lowercased() })
            Log.network.notice("Listing for \(account.subtitle, privacy: .public): \(repos.count, privacy: .public) repos across \(owners.count, privacy: .public) owners")
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
