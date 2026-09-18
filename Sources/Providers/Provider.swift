// Provider.swift — the seam every git host plugs into.
//
// Deliberately narrow: three calls, and everything below it returns the same
// provider-neutral model types. Nothing above this line (AppState, any view)
// knows whether it is talking to GraphQL or REST, or that GitLab calls them
// merge requests. Adding Gitea or Bitbucket later means one new file here plus
// a case in ProviderKind.

import Foundation

protocol Provider: Sendable {
    /// Confirms the token works and returns the login it belongs to. Called
    /// when the user saves an account, not on every poll.
    func verify() async throws -> String

    /// Every repo this token can see, for the picker. Paginated internally.
    func repositories() async throws -> [RemoteRepo]

    /// The numbers for the popover, keyed by `RemoteRepo.fullName`. A repo that
    /// individually failed comes back with its `error` set rather than being
    /// omitted, so the UI can show which one is broken.
    func highlights(for repos: [WatchedRepo]) async throws -> [String: RepoHighlights]

    /// Whether a name on this host belongs to a person or to an organisation.
    /// Asked once at verify time so the UI can say "organisation khaplu" rather
    /// than leaving the user to work out why their token signs in as someone
    /// else. nil means the host could not or would not say.
    func ownerKind(of name: String) async -> OwnerKind?
}

extension Provider {
    /// Providers that cannot answer cheaply inherit "don't know", which callers
    /// already have to handle for a refused or offline lookup.
    func ownerKind(of name: String) async -> OwnerKind? { nil }
}

enum ProviderFactory {
    static func make(account: Account, token: String, http: HTTPClient) -> Provider {
        switch account.kind {
        case .github: return GitHubProvider(account: account, token: token, http: http)
        case .gitlab: return GitLabProvider(account: account, token: token, http: http)
        }
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
