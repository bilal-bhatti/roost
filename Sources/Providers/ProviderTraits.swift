// ProviderTraits.swift — the seam for everything about a host that is *not* a
// network call.
//
// Provider (next door) is the adapter for fetching. This is the adapter for
// knowing: what the host is called, what it calls its own concepts, what kinds
// of credential it issues, where its token form lives and what to tell somebody
// standing in front of that form.
//
// The rule this file exists to enforce: nothing outside Sources/Providers/ may
// branch on which provider it is holding. No `switch kind`, no `== .github`.
// A view asks the traits a question and renders the answer. Adding Gitea is one
// new file in this directory plus one line in ProviderRegistry.all — and the
// compiler lists exactly what the new file must answer.

import Foundation

// MARK: - Provider traits

protocol ProviderTraits: Sendable {
    /// The persisted tag this adapter answers to. The only link between a
    /// stored account and the code that serves it.
    var kind: ProviderKind { get }

    var displayName: String { get }
    /// SF Symbol that stands for the provider wherever accounts are listed.
    var symbolName: String { get }
    /// Host filled in for a new account, and the one treated as the SaaS
    /// instance (anything else is Enterprise / self-hosted).
    var defaultHost: String { get }

    /// The host's own words for its own concepts.
    var lexicon: ProviderLexicon { get }

    /// Every kind of credential this host issues, recommended one first. GitHub
    /// has two that differ in reach; GitLab has one. A provider with one never
    /// shows the user a choice, because there isn't one.
    var credentials: [any Credential] { get }

    /// Longest token name the host's form accepts. Names are generated, so a
    /// silent truncation on their side would produce a token nobody can match
    /// back to an account.
    var tokenNameLimit: Int { get }

    /// Why a repository the user watches can be missing from this host's
    /// listing. Shown in the picker beside the rows it explains.
    var missingRepoHint: String { get }

    func makeProvider(account: Account, token: String, http: HTTPClient) -> Provider
}

extension ProviderTraits {
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
    func tokenName(scope: String, date: Date = Date()) -> String {
        let stamp = TokenNaming.stamp(date)
        let scope = scope.trimmingCharacters(in: .whitespaces)
        guard !scope.isEmpty else { return "Roost \(stamp)" }

        let room = tokenNameLimit - ("Roost () ".count + stamp.count)
        guard room > 1 else { return "Roost \(stamp)" }
        let shown = scope.count <= room
            ? scope
            : String(scope.prefix(max(1, room - 1))) + "…"
        return "Roost (\(shown)) \(stamp)"
    }

    /// The credential a stored token turns out to be, recognised by its prefix.
    /// nil when nothing matches — an empty field, or a host whose tokens carry
    /// no marker.
    func credential(forToken token: String) -> (any Credential)? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        return credentials.first { credential in
            credential.tokenPrefixes.contains { token.hasPrefix($0) }
        }
    }

    /// The credential with this id, or the recommended one. Used to turn the
    /// settings form's selection back into the thing it selected.
    func credential(id: String?) -> any Credential {
        credentials.first { $0.id == id } ?? credentials[0]
    }

    /// What a pasted token implies for this account's scope. The credential
    /// recognises its own prefix and knows what its kind can be bound to; the
    /// provider decides how to *type* any owner it names, which costs a request
    /// on some hosts and nothing on others — so that part stays in the provider.
    ///
    /// An unrecognised token falls back to the recommended credential: the host
    /// still only issues the kinds it issues, and guessing the common one beats
    /// refusing to record a scope at all.
    func binding(forToken token: String, account: Account) -> CredentialBinding {
        (credential(forToken: token) ?? credentials[0]).binding(for: account)
    }

    /// Whether any credential this host issues can be bound to a named owner.
    /// Asked by the account decoder, which has to decide whether an owner stored
    /// by an older build means anything on this host.
    var bindsCredentialsToOwner: Bool {
        credentials.contains { $0.scopeField != nil }
    }
}

enum TokenNaming {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        // Fixed locale and pattern: this string goes into a URL and into the
        // host's token list, and must not shift with the user's region.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    static func stamp(_ date: Date) -> String { formatter.string(from: date) }
}

// MARK: - Credentials

/// The field naming what a credential is scoped to, when the credential has
/// such a concept. GitHub's fine-grained tokens have one ("Resource owner");
/// nothing else Roost speaks to does, so nothing else renders the field.
struct ScopeField: Sendable {
    let label: String
    /// Names the *kind* of thing wanted, not an example value. An earlier
    /// version said "your GitHub login", which reads as an instruction and
    /// produced exactly that on an account meant to point at an org.
    let prompt: String
    /// The longer explanation behind the field's info button.
    let info: String
}

/// What a freshly verified token turns out to reach. Returned by the credential
/// rather than decided by the caller, because only the credential knows whether
/// its own kind of token can be narrowed at all.
enum CredentialBinding: Sendable {
    /// Reaches everything the identity can see; any narrower stored scope is
    /// stale and should be dropped.
    case wholeIdentity
    /// Bound to this named owner. The provider is asked what kind of owner it
    /// is before the scope is recorded.
    case resourceOwner(String)
    /// This kind of token says nothing about scope. Keep what is stored.
    case unchanged
}

/// One kind of token a host issues. Not a global enum: "fine-grained" and
/// "classic" are GitHub's taxonomy, and modelling them app-wide is what forced
/// every GitLab account to carry a token style it does not have.
protocol Credential: Sendable {
    /// Stable identifier, used as the settings picker's selection.
    var id: String { get }
    var displayName: String { get }
    /// How the picker lists it, where the recommendation belongs.
    var pickerLabel: String { get }

    /// What this kind of token actually is, in one honest sentence. Shown under
    /// the choice so the trade-off is visible before the link is clicked, not
    /// discovered afterwards when a repo silently fails to appear.
    var note: String { get }
    /// The permissions to grant, phrased as the host's page presents them.
    var permissionNote: String { get }

    /// Placeholder for the paste field — the token's own prefix, so a token
    /// pasted into the wrong account is visible as wrong.
    var promptPlaceholder: String { get }
    /// Prefixes a token of this kind carries. One list, used to recognise a
    /// stored token and to keep the recognisable part visible when masking it.
    var tokenPrefixes: [String] { get }

    /// The scope field this credential needs, or nil when it has no such
    /// concept and the form should not invent one.
    var scopeField: ScopeField? { get }

    /// Deep link to the host's form for making one of these.
    func creationURL(host: String, scopeName: String) -> URL?

    /// What a token of this kind reaches, given the account it was pasted into.
    func binding(for account: Account) -> CredentialBinding

    /// Instructions for the host's token page, phrased for what this account
    /// actually needs.
    func pageGuidance(for account: Account) -> String?

    /// Short caution shown beside the create button, or nil when there is
    /// nothing to be careful about.
    func caution(for account: Account) -> String?

    /// One line relating the account's two "who" values: the identity the token
    /// signs in as, and whatever it is allowed to reach. Confusing those two is
    /// the single most common way an account ends up watching nothing.
    func reachSummary(for account: Account) -> String
}

extension Credential {
    var pickerLabel: String { displayName }
    var scopeField: ScopeField? { nil }
    func binding(for account: Account) -> CredentialBinding { .unchanged }
    func pageGuidance(for account: Account) -> String? { nil }
    func caution(for account: Account) -> String? { nil }
}

// MARK: - Registry

/// The complete list of hosts Roost speaks to, and the only place a stored
/// `ProviderKind` is turned into the code that serves it.
///
/// A table rather than a `switch` on purpose: a switch here would be the one
/// branch the rest of the app is forbidden, and it would invite a second. The
/// cost is that the compiler cannot prove the table is complete, so the two
/// backstops below stand in for exhaustiveness — an assertion that fires on the
/// first lookup of any debug build, and a precondition that names the missing
/// case rather than silently serving the wrong host's rules.
enum ProviderRegistry {
    static let all: [any ProviderTraits] = [GitHubTraits(), GitLabTraits()]

    private static let byKind: [ProviderKind: any ProviderTraits] = {
        let table = Dictionary(all.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        assert(table.count == ProviderKind.allCases.count,
               "ProviderRegistry.all is missing a ProviderKind. Add its traits type to the list.")
        return table
    }()

    static func traits(for kind: ProviderKind) -> any ProviderTraits {
        guard let traits = byKind[kind] else {
            preconditionFailure("No traits registered for \(kind.rawValue). Add it to ProviderRegistry.all.")
        }
        return traits
    }

    /// "GitHub or GitLab", "GitHub, GitLab or Gitea". Built from the list so
    /// copy that names the supported hosts cannot fall behind the list itself.
    static func names(joinedBy conjunction: String) -> String {
        let names = all.map(\.displayName)
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " \(conjunction) \(last)"
    }
}
