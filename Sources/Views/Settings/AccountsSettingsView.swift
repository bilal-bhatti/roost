// AccountsSettingsView.swift — add, edit and verify accounts.
//
// Two commit rules, and the difference matters:
//
//  * The label is cosmetic, so it saves on every keystroke.
//  * The host is structural — changing it invalidates the watch list, because
//    "acme/api" on a different server is a different repository. So host and
//    token commit on blur or Return, never per keystroke. Typing "gitlab.acme"
//    on the way to "gitlab.acme.com" must not throw anything away.

import SwiftUI

struct AccountsSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            accountList
            Divider()
            detail
        }
        .onAppear { if selection == nil { selection = state.accounts.first?.id } }
    }

    // MARK: - List

    private var accountList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(state.accounts) { account in
                    HStack(spacing: 8) {
                        Image(systemName: account.kind == .github ? "chevron.left.forwardslash.chevron.right" : "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.displayName)
                            Text(account.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(state.repos(for: account).count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .help("Repositories watched through this account")
                    }
                    .tag(account.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: 150)

            addRemoveBar
        }
    }

    /// The +/− strip under a list is the standard macOS affordance for editing
    /// a collection, so the buttons live there rather than in a toolbar.
    private var addRemoveBar: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(ProviderKind.allCases) { kind in
                    Button(kind.displayName) { selection = state.addAccount(kind: kind).id }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help("Add an account")

            Button {
                guard let id = selection, let account = state.account(id: id) else { return }
                state.removeAccount(account)
                selection = state.accounts.first?.id
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .frame(width: 24)
            .disabled(selection == nil)
            .help("Remove the selected account")

            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let account = state.account(id: id) {
            AccountDetailForm(account: account)
                // Rebuild the form (and its drafts) when the selection changes,
                // otherwise one account's half-typed host would bleed into the
                // next one's fields.
                .id(account.id)
        } else {
            ContentUnavailableView {
                Label("No account selected", systemImage: "person.crop.circle")
            } description: {
                Text("Add an account with the + button, or select one to edit it.")
            }
        }
    }
}

// MARK: - Detail form

private struct AccountDetailForm: View {
    let account: Account
    @EnvironmentObject private var state: AppState

    @State private var label: String = ""
    @State private var host: String = ""
    @State private var owner: String = ""
    @State private var token: String = ""
    @State private var status: Status = .idle

    @FocusState private var focusedField: Field?

    private enum Field { case label, host, owner, token }

    private enum Status: Equatable {
        case idle
        case working
        case ok(String)
        /// Verified, but the token doesn't look like it reaches the owner this
        /// account names. Separate from `failed` because the token does work —
        /// it just probably works on the wrong account.
        case warned(String, String)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $label, prompt: Text(account.kind.displayName))
                    .focused($focusedField, equals: .label)
                    // Cosmetic only — safe to persist as it is typed.
                    .onChange(of: label) { _, new in
                        var updated = account
                        updated.label = new
                        state.update(updated)
                    }

                Picker("Provider", selection: providerBinding) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                TextField("Host", text: $host, prompt: Text(account.kind.defaultHost))
                    .focused($focusedField, equals: .host)
                    .onSubmit { commitHost() }

                // GitHub only: a fine-grained token reaches exactly one owner,
                // and recording which one lets the token link target it and
                // lets verify() check afterwards that it really did.
                if account.kind == .github {
                    // The prompt names the *kind* of thing wanted, not an
                    // example value. An earlier version said "your GitHub
                    // login", which reads as an instruction and produced
                    // exactly that on an account meant to point at an org.
                    TextField("Resource owner", text: $owner,
                              prompt: Text("user or organisation"))
                        .focused($focusedField, equals: .owner)
                        .help("The user or organisation that owns the repositories you want to watch. One fine-grained token reaches exactly one of these.")
                        // Cosmetic as far as stored data goes — it only shapes
                        // the token link and the check — so it saves as typed.
                        .onChange(of: owner) { _, new in
                            var updated = account
                            updated.owner = new.trimmingCharacters(in: .whitespaces)
                            state.update(updated)
                        }
                }
            } header: {
                Text("Account")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.isSaaS
                         ? "Using \(account.kind.displayName)'s hosted service."
                         : "Self-hosted or Enterprise instance.")
                    if account.kind == .github {
                        Text("Resource owner is who owns the repositories — your own login for your repos, or an organisation's name for theirs. It is not your login unless these are your own repositories. One fine-grained token reaches exactly one owner, so watching two owners means two accounts here.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                SecureField("Personal access token", text: $token)
                    .focused($focusedField, equals: .token)
                    .onSubmit { commitToken() }
                    // Save as it changes, not only on blur. Clicking from this
                    // field straight to another tab does not reliably move
                    // SwiftUI focus, so a blur-only commit could drop a pasted
                    // token on the floor and then report it as rejected by the
                    // server — a token that had in fact never been sent.
                    .onChange(of: token) { _, _ in commitToken() }

                HStack {
                    // First step for a new account, so it leads. The link
                    // carries the scopes in its query string — the page opens
                    // with them already ticked and nothing else.
                    if let url = account.kind.tokenCreationURL(host: host, owner: owner) {
                        Link("Create Token…", destination: url)
                            .help(account.kind == .github
                                  ? "Opens GitHub's fine-grained token form — the recommended kind, and the only read-only one"
                                  : "Opens \(account.host) with the \(account.kind.requiredScopes) scope already ticked")
                    }
                    // Secondary route, GitHub only: prefilled but write-capable,
                    // and the only single token that spans several owners.
                    if let url = account.kind.classicTokenURL(host: host) {
                        Link("Classic…", destination: url)
                            .help("Legacy classic token with \(account.kind.requiredScopes) pre-ticked. Covers every owner with one token, but repo grants write access.")
                    }
                    Button("Verify") { verify() }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || status == .working)
                    Spacer()
                    statusLabel
                }

                // The full warning needs room to be read and copied; the status
                // slot beside the buttons is too narrow to carry it.
                if case .warned(_, let message) = status {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Authentication")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let guidance = account.tokenPageGuidance {
                        Text(guidance)
                    }
                    Text("Roost only ever reads. The token is stored in your login Keychain, never on disk.")
                    if let permissions = account.kind.fineGrainedPermissions {
                        // Selectable: the form can't be prefilled, so these get
                        // ticked by hand and are worth being able to copy.
                        Text("Give it these, all Read-only: " + permissions.joined(separator: ", ") + ".")
                            .textSelection(.enabled)
                    } else {
                        Text("It asks for \(account.kind.requiredScopes) — the least that lets it count open \(account.kind.changeRequestNoun)s, see which are waiting on you, and read the default branch's check status.")
                    }
                    Text(account.kind.scopeNote)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            label = account.label
            host = account.host
            owner = account.owner
            token = state.token(for: account)
            if !account.username.isEmpty { status = .ok(account.username) }
        }
        // Blur is a commit for the structural fields. Without this, clicking
        // straight from the host field to Verify would verify the old host.
        .onChange(of: focusedField) { old, _ in
            if old == .host { commitHost() }
            if old == .token { commitToken() }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .idle:
            EmptyView()
        case .working:
            ProgressView().controlSize(.small)
        case .ok(let username):
            Label("Signed in as \(username)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        case .warned(let username, _):
            Label("Signed in as \(username)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
                .lineLimit(2)
                .help(message)
        }
    }

    private var providerBinding: Binding<ProviderKind> {
        Binding(
            get: { account.kind },
            set: { kind in
                var updated = account
                updated.kind = kind
                // The old host belongs to the old provider; move to the new
                // one's default rather than leaving a host that can't work.
                updated.host = kind.defaultHost
                updated.username = ""
                state.update(updated)
                host = kind.defaultHost
                status = .idle
            }
        )
    }

    private func commitHost() {
        let normalized = Account.normalizeHost(host)
        guard !normalized.isEmpty, normalized != account.host else {
            host = account.host
            return
        }
        var updated = account
        updated.host = normalized
        updated.username = ""
        state.update(updated)
        host = normalized
        status = .idle
    }

    private func commitToken() {
        guard token != state.token(for: account) else { return }
        if state.setToken(token, for: account) {
            status = .idle
        } else {
            status = .failed("macOS wouldn't save this token to the Keychain.")
        }
    }

    private func verify() {
        commitHost()
        commitToken()
        status = .working
        Task {
            switch await state.verify(account) {
            case .success(let outcome):
                status = outcome.warning.map { .warned(outcome.username, $0) } ?? .ok(outcome.username)
            case .failure(let error):
                status = .failed(Log.describe(error))
            }
        }
    }
}
