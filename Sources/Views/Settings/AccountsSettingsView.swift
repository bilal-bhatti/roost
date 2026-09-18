// AccountsSettingsView.swift — add, edit and verify accounts.
//
// The pane is a sidebar of accounts beside one detail form. The list used to sit
// *above* the form, which cost the form 150pt of height it badly needed and made
// two short things out of one tall one. Side by side, the list is a list and the
// form gets the whole window.
//
// The detail form is numbered, because setting an account up is a sequence and
// not a bag of fields: say where the account points (1), make a token that
// reaches it (2), paste that token back (3). Step 2 is where the old UI lost
// people — it offered two token links side by side with no way to tell which one
// you wanted — so the choice is now stated as a choice, and one button follows it.
//
// Two commit rules, and the difference matters:
//
//  * The scope field is cosmetic as far as stored data goes (it only shapes the
//    token link and the check), so it saves on every keystroke.
//  * The host is structural — changing it invalidates the watch list, because
//    "acme/api" on a different server is a different repository. So host and
//    token commit on blur or Return, never per keystroke. Typing "gitlab.acme"
//    on the way to "gitlab.acme.com" must not throw anything away.

import SwiftUI
import AppKit

struct AccountsSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Metrics.sidebarWidth)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = state.accounts.first?.id } }
        // An account removed elsewhere (or the last one going away) must not
        // leave the detail pane pointing at a ghost.
        .onChange(of: state.accounts) { _, accounts in
            if let selection, !accounts.contains(where: { $0.id == selection }) {
                self.selection = accounts.first?.id
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(state.accounts) { account in
                    AccountSidebarRow(
                        account: account,
                        repoCount: state.repos(for: account).count,
                        error: state.accountErrors[account.id]
                    )
                    .tag(account.id)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if state.accounts.isEmpty {
                    Text("No accounts")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            AddRemoveBar(
                removeHelp: "Remove the selected account",
                canRemove: selection != nil,
                remove: removeSelected
            ) {
                ForEach(ProviderRegistry.all, id: \.kind) { traits in
                    Button("New \(traits.displayName) Account") {
                        selection = state.addAccount(kind: traits.kind).id
                    }
                }
            }
        }
    }

    private func removeSelected() {
        guard let id = selection, let account = state.account(id: id) else { return }
        state.removeAccount(account)
        selection = state.accounts.first?.id
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
                Text("Add a \(ProviderRegistry.names(joinedBy: "or")) account with the + button below the list.")
            }
        }
    }
}

// MARK: - Sidebar row

private struct AccountSidebarRow: View {
    let account: Account
    let repoCount: Int
    let error: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: account.traits.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName)
                    .lineLimit(1)
                // Empty whenever the title already said the host, which is the
                // case for an account with no verified token yet.
                if !account.subtitle.isEmpty {
                    Text(account.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // Head truncation: the tail is the part that
                        // distinguishes two accounts on different instances.
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// One glyph, and it earns its place: a failing account is the reason
    /// somebody opened this pane, so it is visible without selecting anything.
    @ViewBuilder
    private var trailing: some View {
        if let error {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(error)
        } else if account.login.isEmpty {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("No verified token yet")
        } else {
            Text("\(repoCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .help("\(account.lexicon.repoNounPlural.capitalized) watched through this account")
        }
    }

    private var accessibilityLabel: String {
        var parts = [account.displayName, account.subtitle].filter { !$0.isEmpty }
        if let error { parts.append(error) }
        else if account.login.isEmpty { parts.append("no verified token yet") }
        else { parts.append("watching \(account.lexicon.repoCount(repoCount))") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Detail form

private struct AccountDetailForm: View {
    let account: Account
    @EnvironmentObject private var state: AppState

    @State private var host: String = ""
    /// Draft for the selected credential's scope field, when that kind of token
    /// has one. GitHub's resource owner is the only one today.
    @State private var scopeName: String = ""
    /// What is in the Keychain right now, mirrored so the form can render the
    /// masked fingerprint without hitting the Keychain on every layout pass.
    @State private var storedToken: String = ""
    /// What is being typed or pasted. Separate from `storedToken` so the field
    /// can be empty while a perfectly good token stays saved.
    @State private var draftToken: String = ""
    @State private var editingToken = false
    /// Which kind of token step 2 is about to make. An id rather than the
    /// credential itself: the list of kinds belongs to the provider, and this
    /// form only remembers which one was picked.
    @State private var credentialID = ""
    @State private var status: Status = .idle
    @State private var confirmingProvider: ProviderKind?

    @FocusState private var focusedField: Field?

    private enum Field { case host, scope, token }

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
            identitySection
            tokenCreationSection
            tokenEntrySection
        }
        .formStyle(.grouped)
        .onAppear(perform: loadDrafts)
        // Blur is a commit for the structural fields. Without this, clicking
        // straight from the host field to a button would act on the old host.
        .onChange(of: focusedField) { old, _ in
            if old == .host { commitHost() }
            if old == .token { commitToken() }
        }
        // Tab switches and window closes both tear this view down, and neither
        // reliably moves focus first. A pasted token must survive both.
        .onDisappear { commitToken() }
        .confirmationDialog(
            "Change this account to \(confirmingProvider?.traits.displayName ?? "")?",
            isPresented: Binding(get: { confirmingProvider != nil }, set: { if !$0 { confirmingProvider = nil } }),
            presenting: confirmingProvider
        ) { kind in
            Button("Change Provider", role: .destructive) { apply(kind: kind) }
            Button("Cancel", role: .cancel) { confirmingProvider = nil }
        } message: { kind in
            Text("\(account.displayName) watches \(lexicon.repoCount(watchedCount)) on \(account.host). Those entries mean nothing on \(kind.traits.defaultHost), so they will be cleared.")
        }
    }

    private var watchedCount: Int { state.repos(for: account).count }

    /// This host's adapter. Every question below that a form might once have
    /// answered with a `switch` on the provider is asked of it instead.
    private var traits: any ProviderTraits { account.traits }

    /// This provider's own words. Every noun below that names a host concept
    /// comes from here rather than from a GitHub-shaped default.
    private var lexicon: ProviderLexicon { traits.lexicon }

    /// The kind of token step 2 will make and step 3 expects. Falls back to the
    /// recommended one, which is also what a provider with only one kind has.
    private var credential: any Credential { traits.credential(id: credentialID) }

    /// Where the token link should point. The field may be mid-edit or empty,
    /// and a link to `https:///settings/...` is worse than a link to the default.
    private var effectiveHost: String { host.isEmpty ? traits.defaultHost : host }

    // MARK: Step 1 — where

    private var identitySection: some View {
        Section {
            // No name field. An account is titled by what its token reaches,
            // which is both true without maintenance and the only thing that
            // actually differs between two accounts on the same host.
            Picker("Provider", selection: providerBinding) {
                ForEach(ProviderRegistry.all, id: \.kind) { option in
                    Text(option.displayName).tag(option.kind)
                }
            }

            TextField("Host", text: $host, prompt: Text(traits.defaultHost))
                .focused($focusedField, equals: .host)
                .onSubmit { commitHost() }

            // The field appears only where the *selected credential* is bound to
            // something narrower than the identity, which today means GitHub's
            // fine-grained tokens and nothing else. A classic token is bound to
            // no owner and a GitLab personal access token is bound to the
            // person, so an owner field on either would be inventing a setting
            // the host does not have — which is why the credential owns the
            // field rather than the provider.
            if let scopeField = credential.scopeField {
                HStack(spacing: 6) {
                    TextField(scopeField.label, text: $scopeName,
                              prompt: Text(scopeField.prompt))
                        .focused($focusedField, equals: .scope)
                        // Cosmetic as far as stored data goes — it only shapes
                        // the token link and the check — so it saves as typed.
                        .onChange(of: scopeName) { _, new in commitScope(new) }
                    InfoButton(title: scopeField.label, message: scopeField.info)
                }
            }
        } header: {
            StepHeader(1, "Where this account points")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                // The two "who" values are what people confuse, so the sentence
                // that relates them is the first thing under the fields.
                Text(credential.reachSummary(for: account))
                Text(account.isSaaS
                     ? "\(traits.displayName)'s hosted service."
                     : "Self-hosted or Enterprise instance.")
                if watchedCount > 0 {
                    // The wipe is real and silent, so it gets said before it
                    // happens rather than discovered afterwards.
                    Text("Changing the host clears the \(lexicon.repoCount(watchedCount)) this account watches.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Step 2 — create

    private var tokenCreationSection: some View {
        Section {
            // Only where there is genuinely a choice. A host that issues one
            // kind of token never shows a picker of one.
            if traits.credentials.count > 1 {
                Picker("Token type", selection: $credentialID) {
                    ForEach(traits.credentials, id: \.id) { option in
                        Text(option.pickerLabel).tag(option.id)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Text(credential.note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ownerCautionRow

            HStack {
                createTokenButton
                Spacer()
            }
        } header: {
            StepHeader(number: 2, title: "Create a token") {
                if let guidance = credential.pageGuidance(for: account) {
                    InfoButton(title: "On the token page", message: guidance)
                }
            }
        } footer: {
            Text(credential.permissionNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Step 3 — paste

    private var tokenEntrySection: some View {
        Section {
            if editingToken || storedToken.isEmpty {
                SecureField("Token", text: $draftToken, prompt: Text(credential.promptPlaceholder))
                    .font(.system(.body, design: .monospaced))
                    .focused($focusedField, equals: .token)
                    .onSubmit { verify() }

                HStack {
                    Button("Paste") { pasteToken() }
                    Spacer()
                    // Only offered while nothing has been typed, so it can never
                    // mean "throw away what I just pasted".
                    if !storedToken.isEmpty, draftToken.isEmpty {
                        Button("Cancel") { editingToken = false }
                    }
                    Button("Save & Verify") { verify() }
                        .buttonStyle(.borderedProminent)
                        .disabled(draftToken.trimmingCharacters(in: .whitespaces).isEmpty || status == .working)
                }
            } else {
                // A fine-grained token is 93 characters. As secure-field bullets
                // it is an overflowing grey smear that says nothing; as a
                // fingerprint it says which token this is, which is the only
                // question anyone asks of a saved credential.
                LabeledContent("Token") {
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.secondary)
                        Text(Formatting.maskedToken(storedToken))
                            .font(.system(.callout, design: .monospaced))
                        Text("· \(storedToken.count) characters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Formatting.maskedTokenDescription(storedToken))
                }

                HStack {
                    Button("Replace…") {
                        draftToken = ""
                        editingToken = true
                        focusedField = .token
                    }
                    Button("Remove") { removeToken() }
                    Spacer()
                    Button("Verify") { verify() }
                        .disabled(status == .working)
                }
            }

            statusRow
        } header: {
            StepHeader(3, "Paste it back here")
        } footer: {
            Text("Roost only ever reads. The \(lexicon.tokenNoun) is stored in your login Keychain, never on disk, and verifying it resolves the \(lexicon.identityNoun) it signs in as.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Whatever about this kind of token cannot be fixed after it is made.
    ///
    /// Loud while the account has no working token, because a token is about to
    /// be made and the mistake is permanent. Quiet once it verifies, where the
    /// same sentence is a note for the next token rather than a problem now.
    @ViewBuilder
    private var ownerCautionRow: some View {
        if let caution = credential.caution(for: account) {
            let settled = !storedToken.isEmpty && !account.login.isEmpty
            Label(caution, systemImage: settled ? "info.circle" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(settled ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One button, and it opens the form for whichever style is selected above.
    /// It is the loud one only while there is no token saved: once the account
    /// works, making another token is no longer what this pane is for.
    @ViewBuilder
    private var createTokenButton: some View {
        let url = credential.creationURL(host: effectiveHost, scopeName: scopeName)
        let button = Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            Label("Create Token on \(traits.displayName)…", systemImage: "arrow.up.forward.app")
        }
        .disabled(url == nil)

        if storedToken.isEmpty {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    /// Status gets a row of its own rather than a slot beside the buttons. The
    /// old inline slot was too narrow for the messages that matter — a rejected
    /// token's reason, or a token that works on the wrong owner — so those had to
    /// be duplicated underneath, and the copy that fitted said the least.
    @ViewBuilder
    private var statusRow: some View {
        switch status {
        case .idle:
            EmptyView()
        case .working:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking with \(account.host)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ok(let login):
            Label("Verified, signed in as \(login)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .warned(let login, let message):
            VStack(alignment: .leading, spacing: 2) {
                Label("Signed in as \(login)", systemImage: "exclamationmark.triangle.fill")
                Text(message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Editing

    private func loadDrafts() {
        host = account.host
        scopeName = account.resourceOwner ?? ""
        storedToken = state.token(for: account)
        draftToken = ""
        editingToken = storedToken.isEmpty
        // Default the choice in step 2 to whatever kind is already in place, so
        // "make me another one of these" is one click and the notes underneath
        // describe the token the account actually holds. The credential
        // recognises its own token; nothing here knows what a prefix looks like.
        credentialID = (traits.credential(forToken: storedToken) ?? traits.credentials[0]).id
        if !account.login.isEmpty { status = .ok(account.login) }
    }

    private var providerBinding: Binding<ProviderKind> {
        Binding(
            get: { account.kind },
            set: { kind in
                guard kind != account.kind else { return }
                // Switching provider throws the watch list away (the paths mean
                // nothing on the other host). Worth a question when there is
                // something to lose, and worth staying silent when there isn't.
                if watchedCount > 0 {
                    confirmingProvider = kind
                } else {
                    apply(kind: kind)
                }
            }
        )
    }

    private func apply(kind: ProviderKind) {
        var updated = account
        updated.kind = kind
        // The old host belongs to the old provider; move to the new one's
        // default rather than leaving a host that can't work.
        updated.host = kind.traits.defaultHost
        updated.login = ""
        // The old scope was a concept of the old provider. Whatever the new
        // token turns out to reach, verification will record it.
        updated.scope = .wholeIdentity
        state.update(updated)
        host = kind.traits.defaultHost
        scopeName = ""
        status = .idle
        confirmingProvider = nil
        // The old credential was the old host's. Start on the new host's
        // recommended kind, which is also its only kind where it has one.
        credentialID = kind.traits.credentials[0].id
    }

    private func commitHost() {
        let normalized = Account.normalizeHost(host)
        guard !normalized.isEmpty, normalized != account.host else {
            host = account.host
            return
        }
        var updated = account
        updated.host = normalized
        // The login was resolved against the old host and means nothing here.
        updated.login = ""
        state.update(updated)
        host = normalized
        status = .idle
    }

    /// Persists whatever is in the draft field. An empty draft is never a
    /// deletion — "I opened Replace and changed my mind" must not cost a working
    /// token. Removing one is what the Remove button is for.
    private func commitToken() {
        let trimmed = draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != storedToken else { return }
        if state.setToken(trimmed, for: account) {
            storedToken = trimmed
            status = .idle
        } else {
            status = .failed("macOS wouldn't save this token to the Keychain.")
        }
    }

    /// The scope field only shapes the token link and the owner check, so it
    /// saves as it is typed. Clearing it means "not bound to anything I know
    /// of", which is exactly what `.wholeIdentity` says.
    private func commitScope(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        var updated = account
        if name.isEmpty {
            updated.scope = .wholeIdentity
        } else {
            // Keep a kind already resolved for this same name; verify() settles
            // it properly, and guessing "user" over the top of a known
            // organisation would only un-learn something true.
            var kind = OwnerKind.user
            if case .resourceOwner(let existing, let known) = account.scope,
               existing.caseInsensitiveCompare(name) == .orderedSame {
                kind = known
            }
            updated.scope = .resourceOwner(name: name, kind: kind)
        }
        state.update(updated)
    }

    private func pasteToken() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        draftToken = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removeToken() {
        state.setToken("", for: account)
        var updated = account
        updated.login = ""
        state.update(updated)
        storedToken = ""
        draftToken = ""
        editingToken = true
        status = .idle
    }

    private func verify() {
        commitHost()
        commitToken()
        guard !storedToken.isEmpty else {
            status = .failed("There is no token to check yet.")
            return
        }
        status = .working
        Task {
            switch await state.verify(account) {
            case .success(let outcome):
                status = outcome.warning.map { .warned(outcome.login, $0) } ?? .ok(outcome.login)
                // A token that checks out collapses to its fingerprint; the
                // field has done its job and the pane stops looking unfinished.
                draftToken = ""
                editingToken = false
                // verify() may have settled the scope (a name resolved to an
                // organisation, a classic token turning out to reach everything),
                // so the field follows what was actually recorded.
                scopeName = state.account(id: account.id)?.resourceOwner ?? scopeName
            case .failure(let error):
                status = .failed(Log.describe(error))
            }
        }
    }
}
