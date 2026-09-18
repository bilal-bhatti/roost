// GitHubTraits.swift — everything about GitHub that is not a network call.
//
// Sits beside GitHubProvider.swift on purpose: between the two files, this
// directory holds the whole of what Roost *does* differently for GitHub.
// Nothing outside Sources/Providers/ branches on which host it is holding.

import Foundation

struct GitHubTraits: ProviderTraits {
    let kind: ProviderKind = .github
    let displayName = "GitHub"
    let symbolName = "chevron.left.forwardslash.chevron.right"
    let defaultHost = "github.com"
    /// GitHub's cap on the token name field.
    let tokenNameLimit = 40

    let lexicon = ProviderLexicon(
        identityNoun: "login",
        namespaceNoun: "owner",
        repoNoun: "repository",
        repoNounPlural: "repositories",
        changeRequestNoun: "pull request",
        changeRequestAbbreviation: "PR",
        ciNoun: "checks",
        tokenNoun: "personal access token"
    )

    /// Fine-grained first: GitHub marks classic tokens as the legacy option, and
    /// fine-grained is the only kind that can be genuinely read-only.
    let credentials: [any Credential] = [
        GitHubFineGrainedCredential(),
        GitHubClassicCredential(),
    ]

    /// Worth spelling out: the single-resource-owner rule is the most common
    /// reason a repository someone obviously has access to simply isn't there,
    /// and nothing in the GitHub UI says so at the point you'd notice.
    let missingRepoHint = """
        Rows marked with a ? are watched, but this token can't see them.

        A fine-grained token only reaches private repositories owned by its one \
        resource owner; everything else it sees is public. To watch a private \
        repository under another user or organisation, add a second account with \
        a token whose resource owner is that user or organisation.
        """

    func makeProvider(account: Account, token: String, http: HTTPClient) -> Provider {
        GitHubProvider(account: account, token: token, http: http)
    }
}

// MARK: - Resource owners

/// Whether GitHub's resource-owner dropdown has to be changed by hand, which is
/// the case where its prefill bugs bite.
///
/// Three states rather than two, because before a token has been verified there
/// is no login to compare the owner against, and answering "yes" there tells
/// somebody setting up an account under their own login to go and change a
/// dropdown that is already right.
enum OwnerSelection: Sendable {
    /// The owner is the token's own login, or there is no owner to pick.
    case notNeeded
    /// The owner is somebody else: the dropdown must be changed.
    case needed
    /// No verified login yet, so it depends on whether that owner is you.
    case unknown

    /// Only meaningful for a credential that binds to an owner at all; the
    /// classic form has no dropdown to get wrong.
    static func of(_ account: Account) -> OwnerSelection {
        guard let owner = account.resourceOwner else { return .notNeeded }
        guard !account.login.isEmpty else { return .unknown }
        return owner.caseInsensitiveCompare(account.login) == .orderedSame ? .notNeeded : .needed
    }
}

// MARK: - Fine-grained

/// GitHub's current token: read-only, and welded at creation to exactly one
/// resource owner.
struct GitHubFineGrainedCredential: Credential {
    let id = "github.fine-grained"
    let displayName = "Fine-grained"
    let pickerLabel = "Fine-grained (recommended)"
    let promptPlaceholder = "github_pat_…"
    let tokenPrefixes = ["github_pat_"]

    let note = """
        GitHub's current, read-only token. It reaches exactly one resource owner: \
        watching repositories under a second user or organisation means a second \
        account here.
        """

    /// The exact fine-grained permissions Roost needs, in the order they appear
    /// on GitHub's form.
    ///
    /// Note what is *not* here: `Checks`. GitHub does not offer that permission
    /// to fine-grained tokens at all — it is GitHub App only — which is why CI
    /// status falls back to the Actions API when the check-run rollup comes back
    /// denied. `Actions: Read-only` is what makes that fallback work.
    ///
    /// Contents is here for `defaultBranchRef`, not for file contents: GraphQL
    /// refuses that field without it, and refuses it *silently*, returning null
    /// rather than an error. Without the default branch there is nothing to ask
    /// about a branch's CI state.
    static let permissions = [
        "Metadata: Read-only",
        "Contents: Read-only",
        "Pull requests: Read-only",
        "Commit statuses: Read-only",
        "Actions: Read-only",
    ]

    var permissionNote: String {
        "The link pre-ticks these: \(Self.permissions.joined(separator: ", ")). "
            + "GitHub offers fine-grained tokens no Checks permission, so CI status comes from the Actions API instead."
    }

    let scopeField = ScopeField(
        label: "Resource owner",
        prompt: "your login, or an organisation",
        info: """
            The user or organisation that owns the repositories you want to watch: \
            your own login for your own, an organisation's name for theirs. It is \
            not your login unless these are your own repositories.

            One fine-grained token reaches exactly one resource owner, so watching \
            two owners means two accounts here.
            """
    )

    /// GitHub's "PAT template URL" parameters, added August 2025. The permission
    /// keys are the API names of the permissions, which is why "Commit statuses"
    /// is `statuses`.
    ///
    /// `target_name` is sent when the account names an owner, but it is only a
    /// hint: GitHub binds it to the dropdown's display and not to the form state,
    /// so the token is still created under the personal account unless the user
    /// re-selects the owner by hand — and doing that discards every other
    /// parameter here. Both bugs are open (community discussion #188111). The UI
    /// says so plainly, and verification checks afterwards whether the token can
    /// actually reach the named owner, because the resource owner is fixed at
    /// creation and a wrong one can only be fixed by deleting the token.
    func creationURL(host: String, scopeName: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/settings/personal-access-tokens/new"
        var items: [URLQueryItem] = []
        if !scopeName.isEmpty {
            items.append(.init(name: "target_name", value: scopeName))
        }
        components.queryItems = items + [
            .init(name: "name", value: GitHubTraits().tokenName(scope: scopeName)),
            .init(name: "description", value: "Read-only repository monitoring for the Roost menu bar app"),
            // One year. The parameter accepts 1-366 days or `none`; a
            // never-expiring credential for a background app that reads private
            // repositories is not worth the convenience, and a year is long
            // enough that renewing it is a non-event.
            .init(name: "expires_in", value: "365"),
            .init(name: "metadata", value: "read"),
            .init(name: "contents", value: "read"),
            .init(name: "pull_requests", value: "read"),
            .init(name: "statuses", value: "read"),
            .init(name: "actions", value: "read"),
        ]
        return components.url
    }

    /// Bound to one owner. With no owner named yet, the common case is watching
    /// your own repositories, so the login is the right answer — filling it in
    /// beats leaving a field mysteriously empty for the user to guess at.
    func binding(for account: Account) -> CredentialBinding {
        let name = account.resourceOwner ?? account.login
        return name.isEmpty ? .unchanged : .resourceOwner(name)
    }

    func pageGuidance(for account: Account) -> String? {
        guard let owner = account.resourceOwner else {
            return "Name a resource owner above first. A fine-grained token is bound to one, and the binding cannot be changed after the token is made."
        }
        switch OwnerSelection.of(account) {
        case .notNeeded:
            return "The link fills in the name, a one-year expiry and the permissions. Leave Resource owner on your own account."
        case .needed:
            return "This account names \(owner) as its resource owner, and your token signs in as \(account.login). GitHub's page cannot be prefilled for another owner: set Resource owner to \(owner) first, which clears the rest, then set the expiry to 365 days and tick the permissions below. Getting the owner wrong cannot be corrected later; the token has to be deleted and remade."
        case .unknown:
            return "This account names \(owner) as its resource owner. If that is your own login, leave the dropdown alone and the prefilled fields stand. If it is an organisation or another user, set Resource owner to \(owner) first, which clears the rest, then set the expiry to 365 days and tick the permissions below. Getting the owner wrong cannot be corrected later; the token has to be deleted and remade."
        }
    }

    /// The one thing on GitHub's page that cannot be fixed later: a token is
    /// welded to the resource owner it was created under. Phrased for what is
    /// actually known — stated flatly once the login is resolved, conditionally
    /// before it is.
    func caution(for account: Account) -> String? {
        guard let owner = account.resourceOwner else { return nil }
        switch OwnerSelection.of(account) {
        case .notNeeded:
            return nil
        case .needed:
            return "Set Resource owner to \(owner) on the page before anything else. GitHub clears the prefilled fields when you change it."
        case .unknown:
            return "If \(owner) is not your own login, set Resource owner to it on the page before anything else. GitHub clears the prefilled fields when you change it."
        }
    }

    func reachSummary(for account: Account) -> String {
        guard let owner = account.resourceOwner else {
            return "A fine-grained token is bound to one resource owner. Name it above, and the link and the check will both use it."
        }
        guard !account.login.isEmpty else {
            return "This token will be bound to \(owner) and will reach nothing else."
        }
        let who = "@\(account.login)"
        return OwnerSelection.of(account) == .needed
            ? "Signed in as \(who), reading \(owner)'s repositories."
            : "Signed in as \(who), reading your own repositories."
    }
}

// MARK: - Classic

/// GitHub's legacy token, kept as a secondary route because it prefills its
/// scopes and, unlike a fine-grained token, reaches every owner the user can see
/// with one token. The trade is that `repo` grants write access.
struct GitHubClassicCredential: Credential {
    let id = "github.classic"
    let displayName = "Classic"
    let pickerLabel = "Classic (legacy)"
    let promptPlaceholder = "ghp_…"
    /// Every classic form GitHub issues: personal, OAuth, user-to-server,
    /// server-to-server and refresh. Only the first is one a user pastes here,
    /// but recognising the rest keeps a mis-paste from being read as
    /// fine-grained.
    let tokenPrefixes = ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"]

    let note = """
        GitHub's legacy token. One covers every owner you can see, which is why \
        it is still useful, but its repo scope has no read-only form: this token \
        can write to your repositories as well as read them.
        """

    let permissionNote = """
        The link pre-ticks repo and read:org, the least that lets Roost count \
        open pull requests, see which wait on you, and read the default branch's \
        check status.
        """

    /// `scopes` and `description` are GitHub's documented prefill parameters;
    /// the same path exists on Enterprise Server. A classic token spans every
    /// owner, so its name carries the date only.
    func creationURL(host: String, scopeName: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/settings/tokens/new"
        components.queryItems = [
            .init(name: "scopes", value: "repo,read:org"),
            .init(name: "description", value: GitHubTraits().tokenName(scope: "")),
        ]
        return components.url
    }

    /// Not scoped to anything narrower than the identity. Said flatly rather
    /// than left alone: a classic token pasted into an account that names an
    /// owner must clear that owner, or the repo picker filters by a scope the
    /// token was never bound to.
    func binding(for account: Account) -> CredentialBinding { .wholeIdentity }

    /// Nothing to get wrong here: a classic token has no resource owner to pick,
    /// which is exactly what makes it the escape hatch.
    func pageGuidance(for account: Account) -> String? {
        "A classic token is not scoped to an owner, so there is nothing to choose on the page. Check the expiry before you generate it."
    }

    func reachSummary(for account: Account) -> String {
        let who = account.login.isEmpty ? "this token" : "@\(account.login)"
        return "A classic token is not scoped to an owner: it reaches every owner \(who) can see."
    }
}
