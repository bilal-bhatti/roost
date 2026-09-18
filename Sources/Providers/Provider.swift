// Provider.swift — the seam every git host plugs into.
//
// Deliberately narrow: three calls, and everything below it returns the same
// provider-neutral model types. Nothing above this line (AppState, any view)
// knows whether it is talking to GraphQL or REST, or that GitLab calls them
// merge requests. Adding Gitea or Bitbucket later means one new file here plus
// a case in ProviderKind.

import Foundation

/// Everything checking a token taught us about it. One value rather than three
/// calls because the three answers are entangled — what a token reaches decides
/// whether it is worth warning about — and untangling them above this line meant
/// AppState carrying one host's rules about resource owners.
struct Verification: Sendable {
    /// Who the token signs in as.
    let login: String
    /// What it turned out to reach. Resolved from the token itself, not from the
    /// form the user filled in: a classic token pasted into an account that
    /// names an owner gets the truth recorded rather than the intention.
    let scope: TokenScope
    /// The token works, but something about it looks wrong enough to say so.
    let warning: String?
    /// A listing fetched while checking, when the check needed one. Handed back
    /// so the picker's cache can be seeded instead of paging the host twice.
    let repositories: [RemoteRepo]?

    init(login: String, scope: TokenScope, warning: String? = nil, repositories: [RemoteRepo]? = nil) {
        self.login = login
        self.scope = scope
        self.warning = warning
        self.repositories = repositories
    }
}

protocol Provider: Sendable {
    /// Confirms the token works and reports what it is. Called when the user
    /// saves an account, not on every poll.
    func verify() async throws -> Verification

    /// Every repo this token can see, for the picker. Paginated internally.
    func repositories() async throws -> [RemoteRepo]

    /// The numbers for the popover, keyed by `RemoteRepo.fullName`. A repo that
    /// individually failed comes back with its `error` set rather than being
    /// omitted, so the UI can show which one is broken.
    func highlights(for repos: [WatchedRepo]) async throws -> [String: RepoHighlights]
}

enum ProviderFactory {
    /// One line, and no `switch`: which implementation serves an account is the
    /// registry's business (Sources/Providers/ProviderTraits.swift), not this
    /// function's.
    static func make(account: Account, token: String, http: HTTPClient) -> Provider {
        account.traits.makeProvider(account: account, token: token, http: http)
    }
}

// MARK: - Shared plumbing

enum ProviderSupport {
    /// Characters safe to leave unescaped in a single URL path segment. Used to
    /// turn "group/subgroup/project" into one percent-encoded segment, which is
    /// how GitLab addresses a project by path. `.urlPathAllowed` is no good here
    /// because it leaves "/" alone, which is exactly the character that must be
    /// escaped.
    static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encodeSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? value
    }

    /// Runs `work` over `items` with at most `limit` in flight. Providers that
    /// need a request per repo use this so watching 40 repos doesn't open 40
    /// sockets at once and trip abuse detection.
    static func mapConcurrently<Item: Sendable, Output: Sendable>(
        _ items: [Item],
        limit: Int = 4,
        _ work: @escaping @Sendable (Item) async -> Output
    ) async -> [Output] {
        guard !items.isEmpty else { return [] }
        let limit = max(1, min(limit, items.count))

        return await withTaskGroup(of: (Int, Output).self) { group in
            var results = [Output?](repeating: nil, count: items.count)
            var next = 0

            while next < limit {
                let index = next
                group.addTask { (index, await work(items[index])) }
                next += 1
            }
            while let (index, output) = await group.next() {
                results[index] = output
                if next < items.count {
                    let index = next
                    group.addTask { (index, await work(items[index])) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    /// Splits "group/subgroup/project" into namespace and project name. GitLab
    /// namespaces nest, so the split is at the *last* slash, not the first.
    static func splitPath(_ path: String) -> (namespace: String, name: String)? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let namespace = String(path[..<slash])
        let name = String(path[path.index(after: slash)...])
        guard !namespace.isEmpty, !name.isEmpty else { return nil }
        return (namespace, name)
    }
}
