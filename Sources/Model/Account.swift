// Account.swift — one signed-in identity on one host. Roost is deliberately
// multi-account and multi-host: "my work GitLab" and "my personal GitHub" are
// two Accounts, each with its own token, and a watched repo always names the
// account it is read through.
//
// The token itself is never stored here — it lives in the Keychain, keyed by
// the account's id (see Core/Keychain.swift). This type is the part that is
// safe to write to UserDefaults.

import Foundation

/// Which of GitHub's two token forms to make. The two are genuinely different
/// credentials with different reach, and which one you hold decides what Roost
/// can see — so it is a choice the settings form states plainly and then
/// follows, rather than two links sitting side by side hoping to be understood.
///
/// GitLab issues one kind of token, so the choice never appears there.
enum TokenStyle: String, CaseIterable, Identifiable, Sendable {
    case fineGrained
    case classic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fineGrained: return "Fine-grained"
        case .classic:     return "Classic"
        }
    }

    /// The one-line trade-off, shown beside the choice. Read as a pair these
    /// say the whole thing: read-only but one owner, or every owner but write.
    var tagline: String {
        switch self {
        case .fineGrained: return "Read-only, reaches one owner"
        case .classic:     return "Reaches every owner, grants write"
        }
    }
}

/// Which API dialect a host speaks. Adding a provider means adding a case here
/// and a conformance in Providers/, nothing else.
enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case github
    case gitlab

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        }
    }

    /// SF Symbol that stands for the provider wherever accounts are listed.
    var symbolName: String {
        switch self {
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .gitlab: return "arrow.triangle.branch"
        }
    }

    /// Host filled in for a new account, and the one treated as the SaaS
    /// instance (anything else is Enterprise / self-hosted).
    var defaultHost: String {
        switch self {
        case .github: return "github.com"
        case .gitlab: return "gitlab.com"
        }
    }

    // What this provider calls a pull request, a repository, an owner and the
    // rest now lives in ProviderLexicon, reachable as `kind.lexicon`.

    /// The exact fine-grained permissions Roost needs, in the order they appear
    /// on GitHub's form.
    ///
    /// Note what is *not* here: `Checks`. GitHub does not offer that permission
    /// to fine-grained tokens at all — it is GitHub App only — which is why CI
    /// status falls back to the Actions API when the check-run rollup comes
    /// back denied. `Actions: Read-only` is what makes that fallback work.
    var fineGrainedPermissions: [String]? {
        switch self {
        case .github:
            // Contents is here for `defaultBranchRef`, not for file contents:
            // GraphQL refuses that field without it, and refuses it *silently*,
            // returning null rather than an error. Without the default branch
            // there is nothing to ask about a branch's CI state.
            return ["Metadata: Read-only",
                    "Contents: Read-only",
                    "Pull requests: Read-only",
                    "Commit statuses: Read-only",
                    "Actions: Read-only"]
        case .gitlab:
            return nil   // read_api is already read-only; no matrix to fill in.
        }
    }


    /// Deep link to the token form the provider itself recommends.
    ///
    /// For GitHub that is the fine-grained form, not the classic one: GitHub
    /// marks classic tokens as the legacy option, and fine-grained is the only
    /// kind that can be genuinely read-only. It accepts no prefill parameters —
    /// permissions there are a matrix, not a scope list — so the four
    /// permissions are spelled out in the UI beside the link instead.
    ///
    /// GitLab has one kind of token and does accept prefill, so its link lands
    /// on a form that only needs confirming.
    func tokenCreationURL(host: String, resourceOwner: String = "") -> URL? {
        let host = host.isEmpty ? defaultHost : host
        switch self {
        case .github:
            // GitHub's "PAT template URL" parameters, added August 2025. The
            // permission keys are the API names of the permissions, which is
            // why "Commit statuses" is `statuses`.
            //
            // `target_name` is sent when the account names an owner, but it is
            // only a hint: GitHub binds it to the dropdown's display and not to
            // the form state, so the token is still created under the personal
            // account unless the user re-selects the owner by hand — and doing
            // that discards every other parameter here. Both bugs are open
            // (community discussion #188111). The UI says so plainly, and
            // `verify()` checks afterwards whether the token can actually reach
            // the named owner, because the resource owner is fixed at creation
            // and a wrong one can only be fixed by deleting the token.
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = "/settings/personal-access-tokens/new"
            var items: [URLQueryItem] = []
            if !resourceOwner.isEmpty {
                items.append(.init(name: "target_name", value: resourceOwner))
            }
            components.queryItems = items + [
                .init(name: "name", value: Account.tokenName(scope: resourceOwner)),
                .init(name: "description", value: "Read-only repository monitoring for the Roost menu bar app"),
                // One year. The parameter accepts 1-366 days or `none`; a
                // never-expiring credential for a background app that reads
                // private repositories is not worth the convenience, and a
                // year is long enough that renewing it is a non-event.
                .init(name: "expires_in", value: "365"),
                .init(name: "metadata", value: "read"),
                .init(name: "contents", value: "read"),
                .init(name: "pull_requests", value: "read"),
                .init(name: "statuses", value: "read"),
                .init(name: "actions", value: "read"),
            ]
            return components.url
        case .gitlab:
            // GitLab prefills from `name` and `scopes`. The /-/user_settings/
            // path replaced /-/profile/ in GitLab 16. GitLab does not require
            // token names to be unique, but the same naming keeps a list of
            // tokens across both providers readable.
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = "/-/user_settings/personal_access_tokens"
            components.queryItems = [
                .init(name: "name", value: Account.tokenName(scope: resourceOwner)),
                .init(name: "scopes", value: "read_api"),
            ]
            return components.url
        }
    }

    /// GitHub's legacy classic-token form, kept as a secondary route because it
    /// prefills its scopes and, unlike a fine-grained token, reaches every owner
    /// the user can see with one token. The trade is that `repo` grants write
    /// access. GitLab has no equivalent second form.
    func classicTokenURL(host: String, resourceOwner: String = "") -> URL? {
        let host = host.isEmpty ? defaultHost : host
        switch self {
        case .github:
            // `scopes` and `description` are GitHub's documented prefill
            // parameters; the same path exists on Enterprise Server. A classic
            // token spans every owner, so its name carries the date only.
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = "/settings/tokens/new"
            components.queryItems = [
                .init(name: "scopes", value: "repo,read:org"),
                .init(name: "description", value: Account.tokenName(scope: "")),
            ]
            return components.url
        case .gitlab:
            return nil
        }
    }

    /// True when the provider offers a second, legacy token form worth choosing
    /// between. Only GitHub does, so only GitHub's form shows the choice.
    var supportsClassicTokens: Bool { classicTokenURL(host: defaultHost) != nil }

    /// The creation link for whichever style the user picked.
    func tokenURL(style: TokenStyle, host: String, resourceOwner: String = "") -> URL? {
        switch style {
        case .fineGrained: return tokenCreationURL(host: host, resourceOwner: resourceOwner)
        case .classic:     return classicTokenURL(host: host, resourceOwner: resourceOwner)
        }
    }

    /// What this style of token actually is, in one honest sentence. Shown under
    /// the choice so the trade-off is visible before the link is clicked, not
    /// discovered afterwards when a repo silently fails to appear.
    func tokenStyleNote(_ style: TokenStyle) -> String {
        switch (self, style) {
        case (.github, .fineGrained):
            return "GitHub's current, read-only token. It reaches exactly one resource owner: watching repositories under a second user or organisation means a second account here."
        case (.github, .classic):
            return "GitHub's legacy token. One covers every owner you can see, which is why it is still useful, but its repo scope has no read-only form: this token can write to your repositories as well as read them."
        case (.gitlab, _):
            return "GitLab issues one kind of personal access token. read_api is read-only: it cannot modify anything on your account."
        }
    }

    /// The permissions to grant, phrased as the page presents them: a checklist
    /// for fine-grained, a scope list for everything else.
    func tokenPermissionNote(_ style: TokenStyle) -> String {
        switch (self, style) {
        case (.github, .fineGrained):
            let list = (fineGrainedPermissions ?? []).joined(separator: ", ")
            return "The link pre-ticks these: \(list). GitHub offers fine-grained tokens no Checks permission, so CI status comes from the Actions API instead."
        case (.github, .classic):
            return "The link pre-ticks repo and read:org, the least that lets Roost count open pull requests, see which wait on you, and read the default branch's check status."
        case (.gitlab, _):
            return "The link pre-ticks read_api, the least that lets Roost count open merge requests, see which wait on you, and read the default branch's pipeline status."
        }
    }
}

/// Whether a name on a host belongs to a person or to an organisation. GitHub
/// answers this directly (`__typename` on `repositoryOwner`); it matters because
/// "khaplu" alone tells the user nothing, while "organisation khaplu" tells them
/// why their token signs in as somebody else.
enum OwnerKind: String, Codable, Hashable, Sendable {
    case user
    case organisation
}

/// What a credential is allowed to reach.
///
/// This used to be a plain `owner: String` where the empty string meant "not
/// applicable", which is how a GitHub-fine-grained-only idea ended up stored on
/// every GitLab account. As an enum, each provider can only express states it
/// actually has:
///
///  * GitHub fine-grained token: bound to exactly one resource owner.
///  * GitHub classic token, GitLab personal access token: bound to nothing
///    narrower than the identity itself.
///  * GitLab group access token: bound to a group path. Not issued by Roost yet;
///    the case exists so the model does not have to be reopened to add it.
enum TokenScope: Codable, Hashable, Sendable {
    /// Everything the signed-in identity can see.
    case wholeIdentity
    /// GitHub's fine-grained scoping: one user or organisation, fixed at
    /// creation and unchangeable afterwards.
    case resourceOwner(name: String, kind: OwnerKind)
    /// GitLab's group-scoped tokens.
    case group(path: String)

    /// The name the scope points at, or nil when it points at no one thing.
    /// Handy for the repo filter and the token link, which both only care about
    /// "is there a name to narrow by".
    var targetName: String? {
        switch self {
        case .wholeIdentity:              return nil
        case .resourceOwner(let name, _): return name.isEmpty ? nil : name
        case .group(let path):            return path.isEmpty ? nil : path
        }
    }
}

struct Account: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: ProviderKind
    /// Bare hostname, no scheme and no trailing slash ("github.com",
    /// "gitlab.acme.internal"). Normalised on write so the rest of the app can
    /// interpolate it into URLs without re-checking.
    var host: String
    /// Who the token signs in as, resolved from the API by `verify()`. GitHub
    /// calls this a login, GitLab a username; the UI says whichever applies.
    /// Empty until first verified. GitLab needs it to query review requests.
    var login: String

    /// What the token reaches. Distinct from `login` on purpose: a fine-grained
    /// token scoped to an organisation still reports the *person* as
    /// `viewer.login`, so the two differ exactly in the case that matters.
    var scope: TokenScope

    init(
        id: UUID = UUID(),
        kind: ProviderKind,
        host: String? = nil,
        login: String = "",
        scope: TokenScope = .wholeIdentity
    ) {
        self.id = id
        self.kind = kind
        self.host = Account.normalizeHost(host ?? kind.defaultHost)
        self.login = login
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, host, login, scope
    }

    /// Keys written by older builds. Kept in their own enum so the synthesised
    /// `encode(to:)` never tries to write them back. `label` is deliberately
    /// absent: accounts no longer carry a hand-typed name, so an old one has
    /// nowhere to go and is dropped on read.
    private enum LegacyKeys: String, CodingKey {
        case username, owner
    }

    /// Hand-written because the stored shape has changed twice: once when `owner`
    /// was added, and again when `username`/`owner` became `login`/`scope`.
    /// Accounts saved by any of those builds decode here without the user
    /// noticing a thing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ProviderKind.self, forKey: .kind)
        host = try container.decode(String.self, forKey: .host)
        login = try container.decodeIfPresent(String.self, forKey: .login)
            ?? legacy.decodeIfPresent(String.self, forKey: .username)
            ?? ""

        if let scope = try container.decodeIfPresent(TokenScope.self, forKey: .scope) {
            self.scope = scope
        } else {
            // A legacy `owner` was only ever meaningful on GitHub, and the old
            // model had nowhere to record whether it named a person or an org.
            // `.user` is the safe guess: `verify()` corrects it on the next
            // check, and the only thing riding on it before then is one word of
            // display text.
            let legacyOwner = (try legacy.decodeIfPresent(String.self, forKey: .owner) ?? "")
                .trimmingCharacters(in: .whitespaces)
            self.scope = (kind == .github && !legacyOwner.isEmpty)
                ? .resourceOwner(name: legacyOwner, kind: .user)
                : .wholeIdentity
        }
    }

    /// What to call this account in a list.
    ///
    /// Derived, never typed. Roost used to ask for a name here and seed it with
    /// the provider's own ("GitHub"), which gave every account on a host the
    /// same title while the one thing that actually differed sat in the subtitle
    /// underneath. What a credential reaches is both distinguishing and true
    /// without anyone maintaining it, so that is the title; the host carries it
    /// until a token says otherwise.
    var displayName: String { scopeLabel ?? host }

    /// The scope in the provider's own words, or nil when there is nothing to
    /// say. GitHub: "khaplu (organisation)". GitLab: "@bilal", because a personal
    /// access token is scoped to the person and that is the honest answer.
    var scopeLabel: String? {
        switch scope {
        case .resourceOwner(let name, let kind):
            guard !name.isEmpty else { return nil }
            return kind == .organisation ? "\(name) (organisation)" : name
        case .group(let path):
            guard !path.isEmpty else { return nil }
            return "group \(path)"
        case .wholeIdentity:
            return login.isEmpty ? nil : "@\(login)"
        }
    }

    /// The resource owner this account's token is bound to, if it is bound to
    /// one. Nil for classic and GitLab tokens, which is the point of asking.
    var resourceOwner: String? {
        guard case .resourceOwner(let name, _) = scope, !name.isEmpty else { return nil }
        return name
    }

    /// Secondary line for account lists: where the account points, or nothing
    /// when the title already had to say it.
    var subtitle: String { displayName == host ? "" : host }

    /// Both lines joined, for a picker menu that has no second line.
    var pickerTitle: String {
        subtitle.isEmpty ? displayName : "\(displayName) · \(subtitle)"
    }

    /// Whether GitHub's resource-owner dropdown has to be changed by hand, which
    /// is the case where its prefill bugs bite.
    ///
    /// Three states rather than two, because before a token has been verified
    /// there is no login to compare the owner against, and answering "yes" there
    /// tells somebody setting up an account under their own login to go and
    /// change a dropdown that is already right.
    enum OwnerSelection {
        /// The owner is the token's own login, or there is no owner to pick.
        case notNeeded
        /// The owner is somebody else: the dropdown must be changed.
        case needed
        /// No verified login yet, so it depends on whether that owner is you.
        case unknown
    }

    var resourceOwnerSelection: OwnerSelection {
        guard kind == .github, let owner = resourceOwner else { return .notNeeded }
        guard !login.isEmpty else { return .unknown }
        return owner.caseInsensitiveCompare(login) == .orderedSame ? .notNeeded : .needed
    }

    /// The short caution shown beside the create button, or nil when there is
    /// nothing to be careful about. Phrased for what is actually known: stated
    /// flatly once the login is resolved, conditionally before it is.
    func ownerCaution(style: TokenStyle) -> String? {
        guard kind == .github, style == .fineGrained, let owner = resourceOwner else { return nil }
        switch resourceOwnerSelection {
        case .notNeeded:
            return nil
        case .needed:
            return "Set Resource owner to \(owner) on the page before anything else. GitHub clears the prefilled fields when you change it."
        case .unknown:
            return "If \(owner) is not your own login, set Resource owner to it on the page before anything else. GitHub clears the prefilled fields when you change it."
        }
    }

    /// Instructions for the token page, phrased for what this account actually
    /// needs. The orderings are genuinely different work, so they get genuinely
    /// different wording rather than one hedged paragraph.
    func tokenPageGuidance(style: TokenStyle) -> String? {
        guard kind == .github else { return nil }
        guard style == .fineGrained else {
            // Nothing to get wrong here: a classic token has no resource owner
            // to pick, which is exactly what makes it the escape hatch.
            return "A classic token is not scoped to an owner, so there is nothing to choose on the page. Check the expiry before you generate it."
        }
        guard let owner = resourceOwner else {
            return "Name a resource owner above first. A fine-grained token is bound to one, and the binding cannot be changed after the token is made."
        }
        switch resourceOwnerSelection {
        case .notNeeded:
            return "The link fills in the name, a one-year expiry and the permissions. Leave Resource owner on your own account."
        case .needed:
            return "This account names \(owner) as its resource owner, and your token signs in as \(login). GitHub's page cannot be prefilled for another owner: set Resource owner to \(owner) first, which clears the rest, then set the expiry to 365 days and tick the permissions below. Getting the owner wrong cannot be corrected later; the token has to be deleted and remade."
        case .unknown:
            return "This account names \(owner) as its resource owner. If that is your own login, leave the dropdown alone and the prefilled fields stand. If it is an organisation or another user, set Resource owner to \(owner) first, which clears the rest, then set the expiry to 365 days and tick the permissions below. Getting the owner wrong cannot be corrected later; the token has to be deleted and remade."
        }
    }

    /// True for the provider's hosted service, false for Enterprise/self-hosted.
    /// Only affects API base URLs, never behaviour the user sees.
    var isSaaS: Bool { host.caseInsensitiveCompare(kind.defaultHost) == .orderedSame }

    /// GitHub's cap on the token name field.
    private static let maxTokenNameLength = 40

    private static let tokenNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Fixed locale and pattern: this string goes into a URL and into
        // GitHub's token list, and must not shift with the user's region.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    /// Name for the token a creation link will make: `Roost (khaplu) 2026-09`.
    ///
    /// `scope` is whatever the token will be bound to (a GitHub resource owner,
    /// later a GitLab group) or empty when it is bound to nothing narrower than
    /// the identity. GitHub requires fine-grained token names to be unique per
    /// user, so both parts earn their place: the scope keeps two accounts from
    /// colliding, and the year-month keeps next year's replacement from
    /// colliding with the token it replaces, which is normally still there
    /// because you create the new one before deleting the old.
    ///
    /// Truncation eats into the scope, never the prefix: a name beginning
    /// "Roost" stays recognisable in a list of unrelated tokens.
    static func tokenName(scope: String, date: Date = Date()) -> String {
        let stamp = tokenNameFormatter.string(from: date)
        let scope = scope.trimmingCharacters(in: .whitespaces)
        guard !scope.isEmpty else { return "Roost \(stamp)" }

        let room = maxTokenNameLength - ("Roost () ".count + stamp.count)
        let shown = scope.count <= room
            ? scope
            : String(scope.prefix(max(1, room - 1))) + "…"
        return "Roost (\(shown)) \(stamp)"
    }

    /// Accepts whatever the user pasted — "https://gitlab.acme.com/", with or
    /// without a scheme or path — and reduces it to a bare host.
    static func normalizeHost(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        while s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }
}
