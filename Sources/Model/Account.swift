// Account.swift — one signed-in identity on one host. Roost is deliberately
// multi-account and multi-host: "my work GitLab" and "my personal GitHub" are
// two Accounts, each with its own token, and a watched repo always names the
// account it is read through.
//
// The token itself is never stored here — it lives in the Keychain, keyed by
// the account's id (see Core/Keychain.swift). This type is the part that is
// safe to write to UserDefaults.
//
// Nothing in this file names a host. Every question that used to be answered by
// a `switch kind` here — where the token form is, what the host calls its
// tokens, what to warn about before you make one — is now asked of
// `traits` (Sources/Providers/ProviderTraits.swift).

import Foundation

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
    /// One user or organisation, fixed at creation and unchangeable afterwards.
    case resourceOwner(name: String, kind: OwnerKind)
    /// Group-scoped tokens.
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
    /// Who the token signs in as, resolved from the API when the account is
    /// verified. GitHub calls this a login, GitLab a username; the UI says
    /// whichever applies. Empty until first verified.
    var login: String

    /// What the token reaches. Distinct from `login` on purpose: a fine-grained
    /// token scoped to an organisation still reports the *person* as the signed-
    /// in user, so the two differ exactly in the case that matters.
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
        self.host = Account.normalizeHost(host ?? kind.traits.defaultHost)
        self.login = login
        self.scope = scope
    }

    /// The adapter for this account's host. The single door to everything
    /// provider-specific; nothing here branches on which host it is.
    var traits: any ProviderTraits { kind.traits }

    /// The host's own words, for UI that names a host concept.
    var lexicon: ProviderLexicon { traits.lexicon }

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
            // A legacy `owner` only means anything on a host that binds tokens
            // to a named owner at all, and the old model had nowhere to record
            // whether that name was a person or an org. `.user` is the safe
            // guess: verification corrects it on the next check, and the only
            // thing riding on it before then is one word of display text.
            let legacyOwner = (try legacy.decodeIfPresent(String.self, forKey: .owner) ?? "")
                .trimmingCharacters(in: .whitespaces)
            self.scope = (kind.traits.bindsCredentialsToOwner && !legacyOwner.isEmpty)
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
    /// say. "khaplu (organisation)" for a token bound to one owner; "@bilal"
    /// where the credential is scoped to the person and that is the honest
    /// answer.
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
    /// one. Nil for credentials that reach the whole identity, which is the
    /// point of asking.
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

    /// True for the provider's hosted service, false for Enterprise/self-hosted.
    /// Only affects API base URLs, never behaviour the user sees.
    var isSaaS: Bool { host.caseInsensitiveCompare(traits.defaultHost) == .orderedSame }

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
