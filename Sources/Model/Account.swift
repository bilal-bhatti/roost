// Account.swift — one signed-in identity on one host. Roost is deliberately
// multi-account and multi-host: "my work GitLab" and "my personal GitHub" are
// two Accounts, each with its own token, and a watched repo always names the
// account it is read through.
//
// The token itself is never stored here — it lives in the Keychain, keyed by
// the account's id (see Core/Keychain.swift). This type is the part that is
// safe to write to UserDefaults.

import Foundation

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

    /// Host filled in for a new account, and the one treated as the SaaS
    /// instance (anything else is Enterprise / self-hosted).
    var defaultHost: String {
        switch self {
        case .github: return "github.com"
        case .gitlab: return "gitlab.com"
        }
    }

    /// What the provider calls a change request. Used in every user-facing
    /// string so GitLab users see "MR", not a GitHub-ism.
    var changeRequestAbbreviation: String {
        switch self {
        case .github: return "PR"
        case .gitlab: return "MR"
        }
    }

    var changeRequestNoun: String {
        switch self {
        case .github: return "pull request"
        case .gitlab: return "merge request"
        }
    }

    /// The narrowest scopes that make Roost work. Shown verbatim in Settings so
    /// there's no guessing.
    var requiredScopes: String {
        switch self {
        // `repo` is the load-bearing one — without it the API returns nothing
        // for private repositories. `read:org` only affects whether
        // organisation-owned repos appear in the picker.
        case .github: return "repo, read:org"
        case .gitlab: return "read_api"
        }
    }

    /// Honest note about how read-only the token actually is. The two providers
    /// differ here and the difference is worth stating rather than hiding.
    var scopeNote: String {
        switch self {
        case .github:
            // Classic tokens have no read-only equivalent of `repo`:
            // `public_repo` is write access to public repos, and there is no
            // `read:repo`. Fine-grained tokens are the only read-only option,
            // which is why they are the default route here.
            return "GitHub does not offer fine-grained tokens a Checks permission, so check-run status comes from the Actions API instead. The classic alternative reaches every owner with a single token, but its repo scope has no read-only form and grants write access too."
        case .gitlab:
            return "read_api is read-only: it cannot modify anything on your account."
        }
    }

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
    func tokenCreationURL(host: String, owner: String = "") -> URL? {
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
            if !owner.isEmpty {
                items.append(.init(name: "target_name", value: owner))
            }
            components.queryItems = items + [
                .init(name: "name", value: Account.tokenName(owner: owner)),
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
                .init(name: "name", value: Account.tokenName(owner: owner)),
                .init(name: "scopes", value: "read_api"),
            ]
            return components.url
        }
    }

    /// GitHub's legacy classic-token form, kept as a secondary route because it
    /// prefills its scopes and, unlike a fine-grained token, reaches every owner
    /// the user can see with one token. The trade is that `repo` grants write
    /// access. GitLab has no equivalent second form.
    func classicTokenURL(host: String, owner: String = "") -> URL? {
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
                .init(name: "description", value: Account.tokenName(owner: "")),
            ]
            return components.url
        case .gitlab:
            return nil
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
    /// What the user calls this account in the UI ("Work", "Personal").
    var label: String
    /// Login resolved from the API by `verify()`. Empty until first verified;
    /// GitLab needs it to query review requests by username.
    var username: String

    /// GitHub only: the user or organisation this account's token is scoped to.
    ///
    /// Distinct from `username` on purpose. A fine-grained token scoped to an
    /// organisation still reports the *person* as `viewer.login`, so the two
    /// differ exactly in the case that matters. It is also fixed at token
    /// creation and can never be changed, which is why it is worth recording
    /// rather than guessing.
    var owner: String

    init(
        id: UUID = UUID(),
        kind: ProviderKind,
        host: String? = nil,
        label: String = "",
        username: String = "",
        owner: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.host = Account.normalizeHost(host ?? kind.defaultHost)
        self.label = label
        self.username = username
        self.owner = owner
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, host, label, username, owner
    }

    /// Hand-written so accounts stored before `owner` existed still decode.
    /// The synthesised initialiser treats a missing key as an error even when
    /// the property has a default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ProviderKind.self, forKey: .kind)
        host = try container.decode(String.self, forKey: .host)
        label = try container.decode(String.self, forKey: .label)
        username = try container.decode(String.self, forKey: .username)
        owner = try container.decodeIfPresent(String.self, forKey: .owner) ?? ""
    }

    /// Non-empty name for lists: the user's label, else the host.
    var displayName: String {
        label.trimmingCharacters(in: .whitespaces).isEmpty ? host : label
    }

    /// Secondary line for account lists.
    ///
    /// Deliberately the resource owner and not `username`. A fine-grained token
    /// scoped to an organisation still reports the *person* as its login, so
    /// `username` is identical for every GitHub account you will ever add — a
    /// field that looks informative while carrying no information. The owner is
    /// the only thing that actually differs.
    var subtitle: String {
        let owner = owner.trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty else { return host }
        return "\(owner) · \(host)"
    }

    /// Name and owner on one line, for a picker menu that has no second line to
    /// put the owner on. Collapses to just the name when the two would repeat.
    var pickerTitle: String {
        let owner = owner.trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty,
              owner.caseInsensitiveCompare(displayName) != .orderedSame
        else { return displayName }
        return "\(displayName) · \(owner)"
    }

    /// True when the named owner is somebody other than the token's own user —
    /// i.e. the case where GitHub's resource-owner dropdown has to be changed
    /// by hand, which is the case where its prefill bugs bite.
    var ownerNeedsSelecting: Bool {
        let owner = owner.trimmingCharacters(in: .whitespaces)
        guard kind == .github, !owner.isEmpty else { return false }
        return owner.caseInsensitiveCompare(username) != .orderedSame
    }

    /// Instructions for the token page, phrased for what this account actually
    /// needs. The two orderings are genuinely different work, so they get
    /// genuinely different wording rather than one hedged paragraph.
    var tokenPageGuidance: String? {
        guard kind == .github else { return nil }
        if ownerNeedsSelecting {
            return "This account names \(owner) as its resource owner. GitHub's page cannot be prefilled for another owner: set Resource owner to \(owner) on the page first — that clears the rest — then set the expiry to 365 days and tick the permissions below. Getting the owner wrong cannot be corrected later; the token has to be deleted and remade."
        }
        return "The link fills in the name, a one-year expiry and the permissions. Leave Resource owner on your own account."
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

    /// Name for the token a creation link will make: `Roost (owner) 2026-09`.
    ///
    /// GitHub requires fine-grained token names to be unique per user, so both
    /// parts earn their place. The owner keeps two accounts from colliding.
    /// The year-month keeps next year's replacement from colliding with the
    /// token it replaces — which is normally still there, because you create
    /// the new one before deleting the old.
    ///
    /// Truncation eats into the owner, never the prefix: a name beginning
    /// "Roost" stays recognisable in a list of unrelated tokens.
    static func tokenName(owner: String, date: Date = Date()) -> String {
        let stamp = tokenNameFormatter.string(from: date)
        let owner = owner.trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty else { return "Roost \(stamp)" }

        let room = maxTokenNameLength - ("Roost () ".count + stamp.count)
        let shown = owner.count <= room
            ? owner
            : String(owner.prefix(max(1, room - 1))) + "…"
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
