// GitHubProvider.swift — GitHub.com and GitHub Enterprise Server, over GraphQL.
//
// Why GraphQL rather than REST: the popover needs three numbers per repo (open
// PRs, review requests, default-branch check status). Over REST that is three
// round trips per repo — 60 requests for 20 repos, every poll. Over GraphQL it
// is one request per *account*: every watched repo becomes an aliased
// `repository(...)` field in a single document, and the review-request count
// comes from one `search` field in the same query.
//
// GitHub meters GraphQL by query cost (5,000 points/hour), not request count,
// and a batch like this costs a handful of points, so a one-minute poll across
// dozens of repos sits far inside the budget.
//
// Enterprise differs only in the base URL: api.github.com vs https://host/api.

import Foundation

struct GitHubProvider: Provider {
    let account: Account
    let token: String
    let http: HTTPClient

    /// GitHub.com puts the API on a separate host; Enterprise mounts it under
    /// the instance itself.
    private var endpoint: URL? {
        account.isSaaS
            ? URL(string: "https://api.github.com/graphql")
            : URL(string: "https://\(account.host)/api/graphql")
    }

    // MARK: - Provider

    func verify() async throws -> Verification {
        let data: ViewerLogin = try await perform("query { viewer { login } }").data
        var verified = account
        verified.login = data.viewer.login
        verified.scope = await resolvedScope(for: verified)

        // Public repos are visible to every token regardless of scope, so only a
        // private one proves the token really reaches this owner — which means
        // the check needs a listing, and the caller may as well keep it.
        guard case .needed = OwnerSelection.of(verified),
              let owner = verified.resourceOwner,
              let repos = try? await repositories()
        else {
            return Verification(login: verified.login, scope: verified.scope)
        }
        let reachesOwner = repos.contains {
            $0.isPrivate && $0.namespace.caseInsensitiveCompare(owner) == .orderedSame
        }
        return Verification(
            login: verified.login,
            scope: verified.scope,
            warning: reachesOwner ? nil : Self.wrongOwnerWarning(login: verified.login, owner: owner),
            repositories: repos
        )
    }

    /// What the just-verified token actually reaches.
    ///
    /// The token itself is the evidence, not the form the user filled in: which
    /// kind of credential it is decides whether it is bound to an owner at all,
    /// and the credential knows its own prefix. A user who pastes a classic
    /// token into an account that names an owner gets the truth recorded rather
    /// than the intention, which is what stops the repo picker from filtering by
    /// an owner the token was never scoped to.
    private func resolvedScope(for account: Account) async -> TokenScope {
        switch account.traits.binding(forToken: token, account: account) {
        case .unchanged:
            return account.scope
        case .wholeIdentity:
            return .wholeIdentity
        case .resourceOwner(let name):
            let kind = await ownerKind(of: name)
                // Unreachable or refused: fall back to the one thing we can
                // infer. A resource owner that isn't you is an organisation far
                // more often than it is a second personal account.
                ?? (name.caseInsensitiveCompare(account.login) == .orderedSame ? .user : .organisation)
            return .resourceOwner(name: name, kind: kind)
        }
    }

    /// Why a token scoped to somebody else's account might not reach them.
    ///
    /// This exists because of a specific, open GitHub bug: the token page's
    /// `target_name` parameter sets the Resource owner dropdown's *appearance*
    /// without setting the form, so a token can be created under the personal
    /// account while looking correct throughout. A fine-grained token's resource
    /// owner is fixed at creation, so the only cure is deletion — which makes
    /// catching it at verify time, rather than at the first confusing empty repo
    /// list, worth a request.
    private static func wrongOwnerWarning(login: String, owner: String) -> String {
        "Signed in as \(login), but this token can't see any private repository owned by \(owner). Its resource owner is probably your personal account, and that can't be changed after the token is created: delete it and make a new one with Resource owner set to \(owner) on the page itself."
    }

    /// GitHub types its owners in the schema, so one small query settles whether
    /// a name is a person or an organisation. `repositoryOwner` needs no
    /// permission beyond what any working token already has, and a refusal is
    /// answered with nil rather than a guess.
    private func ownerKind(of name: String) async -> OwnerKind? {
        guard !name.isEmpty else { return nil }
        let query = "query($login: String!) { repositoryOwner(login: $login) { __typename } }"
        guard let response: Response<RepositoryOwnerType> = try? await perform(query, variables: ["login": name]),
              let typename = response.data.repositoryOwner?.__typename
        else { return nil }
        switch typename {
        case "Organization": return .organisation
        case "User":         return .user
        default:             return nil
        }
    }

    /// Listing is the one call that goes over REST rather than GraphQL.
    ///
    /// GraphQL's `viewer.repositories` connection is only dependable for a
    /// classic token. A fine-grained token is scoped to a single resource owner
    /// and an explicit repository selection, and GitHub documents
    /// `GET /user/repos` — not the GraphQL connection — as the endpoint that
    /// works with fine-grained tokens, needing only `Metadata: Read`. Since
    /// fine-grained is the kind GitHub recommends and the only read-only kind,
    /// the listing follows the endpoint that serves both.
    ///
    /// Batching is irrelevant here (this is one collection, not N repos), and
    /// REST brings ETags, so reopening the picker costs a 304.
    func repositories() async throws -> [RemoteRepo] {
        var out: [RemoteRepo] = []
        // Ten pages of 100. A cap matters: without one, a token on an account
        // in a large org would page for a very long time behind a spinner.
        for page in 1...10 {
            let request = try makeRESTRequest("/user/repos", query: [
                .init(name: "per_page", value: "100"),
                .init(name: "page", value: String(page)),
                .init(name: "sort", value: "pushed"),
                .init(name: "affiliation", value: "owner,collaborator,organization_member"),
            ])

            let items: [RESTRepo]
            do {
                items = try await http.send(request, cacheKey: cacheKey(request)).decode([RESTRepo].self)
            } catch {
                // Name the page: "it failed on page 3" and "it failed
                // immediately" have completely different causes. Cancellation
                // isn't either of them — it means the picker moved on — so it
                // stays out of the error log rather than sitting there looking
                // like a cause.
                if !Log.isCancellation(error) {
                    Log.network.error("Repository page \(page, privacy: .public) failed: \(Log.describe(error), privacy: .public)")
                }
                throw error
            }
            Log.network.notice("Repository page \(page, privacy: .public): \(items.count, privacy: .public) repos")

            out.append(contentsOf: items.compactMap { item in
                guard let login = item.owner?.login else { return nil }
                return RemoteRepo(namespace: login, name: item.name,
                                  isPrivate: item.isPrivate, isArchived: item.archived ?? false)
            })
            if items.count < 100 { break }
        }
        return out
    }

    func highlights(for repos: [WatchedRepo]) async throws -> [String: RepoHighlights] {
        guard !repos.isEmpty else { return [:] }

        // One search covers every repo at once, so it happens outside the loop.
        // If it fails the rest is still worth showing — but nil is kept distinct
        // from an empty dictionary. A fine-grained token is bound to a single
        // resource owner and frequently cannot run this cross-owner search, and
        // reporting that as "0 reviews waiting" would be a confident lie about
        // the one number Roost exists to surface.
        let reviewCounts = try? await reviewRequestCounts()

        var out: [String: RepoHighlights] = [:]
        var ciFallback: [CIFallback] = []
        // 40 repos per document. GitHub rejects very large queries on node-count
        // grounds, and a smaller batch also means one bad chunk loses less.
        for chunk in repos.chunked(into: 40) {
            var query = "query("
            query += chunk.indices.map { "$o\($0): String!, $n\($0): String!" }.joined(separator: ", ")
            query += ") {\n"
            for index in chunk.indices {
                query += "  r\(index): repository(owner: $o\(index), name: $n\(index)) { ...H }\n"
            }
            query += "}\n" + Query.highlightsFragment

            var variables: [String: Any] = [:]
            for (index, repo) in chunk.enumerated() {
                variables["o\(index)"] = repo.namespace
                variables["n\(index)"] = repo.name
            }

            let response: Response<RepoBatch>
            do {
                response = try await perform(query, variables: variables)
            } catch {
                // Whole chunk failed (network, auth, rate limit). Mark its repos
                // so the UI shows which ones are stale instead of silently
                // dropping them.
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                for repo in chunk {
                    out[repo.fullName] = RepoHighlights(error: message)
                }
                continue
            }

            // A repo the token can't see comes back as a null field plus an
            // entry in `errors` pointing at that alias. Map alias -> message so
            // each missing repo gets its own explanation.
            var aliasErrors: [String: String] = [:]
            for error in response.errors {
                guard let path = error.path, let alias = path.first else { continue }
                // Anything under a repository alias that isn't the repository
                // itself is a partial refusal: the PR count still arrived, so
                // don't blank the row over it.
                if path.count > 1 {
                    Log.network.notice("GraphQL partial refusal at \(path.joined(separator: "."), privacy: .public): \(error.message, privacy: .public)")
                } else {
                    aliasErrors[alias] = error.message
                }
            }

            for (index, repo) in chunk.enumerated() {
                let alias = "r\(index)"
                guard let node = response.data.repos[alias] else {
                    out[repo.fullName] = RepoHighlights(
                        error: aliasErrors[alias] ?? "Not visible to this token."
                    )
                    continue
                }
                let rollupState = node.defaultBranchRef?.target?.statusCheckRollup?.state
                let highlights = RepoHighlights(
                    openChangeRequests: node.pullRequests.totalCount,
                    reviewRequests: reviewCounts?[node.nameWithOwner.lowercased()] ?? 0,
                    reviewRequestsAvailable: reviewCounts != nil,
                    ci: rollupState.map(Self.mapRollup) ?? .unknown,
                    defaultBranch: node.defaultBranchRef?.name,
                    url: node.url
                )
                // Any missing rollup queues the fallback, not just an explicitly
                // refused one. GitHub returns null here with no error at all
                // when the token can't reach checks, so waiting for an error
                // meant the fallback never ran and every repo reported "No
                // checks" — a confident answer nobody had actually asked for.
                // The branch may be nil too (`defaultBranchRef` is refused
                // without Contents: Read), so the fallback resolves it.
                if rollupState == nil {
                    ciFallback.append(CIFallback(fullName: repo.fullName, namespace: repo.namespace,
                                                 name: repo.name, branch: node.defaultBranchRef?.name))
                }
                out[repo.fullName] = highlights
            }
        }

        // GitHub does not grant fine-grained tokens a Checks permission at all,
        // so for those tokens the rollup is always refused and this is the only
        // route to a CI state. Actions runs cover GitHub Actions; CI that
        // reports through the older commit-status API is not visible this way,
        // which is why classic tokens keep using the rollup.
        if !ciFallback.isEmpty {
            Log.network.notice("No check rollup for \(ciFallback.count, privacy: .public) repos; resolving CI over REST")
            let results = await ProviderSupport.mapConcurrently(ciFallback) { await fallbackCIStatus($0) }
            for (entry, result) in zip(ciFallback, results) {
                out[entry.fullName]?.ci = result.status
                if out[entry.fullName]?.defaultBranch == nil {
                    out[entry.fullName]?.defaultBranch = result.branch
                }
            }
        }
        return out
    }

    /// CI state for a branch without the Checks API.
    ///
    /// GitHub will not grant fine-grained tokens a `Checks` permission, so the
    /// check-run rollup is unreachable for them. Two of the three things that
    /// rollup folds together are still reachable separately:
    ///
    ///  * GitHub Actions runs, via `Actions: Read`.
    ///  * Legacy commit statuses, via `Commit statuses: Read`. This is how CI
    ///    that predates the Checks API reports, and a repo using it has no
    ///    workflow runs at all.
    ///
    /// Actions is tried first because it answers the common case; the status
    /// API is only consulted when there are no runs, so the usual path stays at
    /// one request. What remains genuinely invisible is third-party CI that
    /// reports as *check runs* through a GitHub App integration — that needs
    /// the Checks API, and no PAT can read it.
    private func fallbackCIStatus(_ entry: CIFallback) async -> CIResult {
        // GraphQL may not have given us a branch either — `defaultBranchRef` is
        // refused without Contents: Read, and silently. REST metadata always
        // carries it and needs only Metadata: Read.
        // Written out rather than `entry.branch ?? await …`: the right-hand
        // side of `??` is an autoclosure, which can't be async.
        var resolved = entry.branch
        if resolved == nil { resolved = await defaultBranch(entry) }
        guard let branch = resolved else {
            return CIResult(status: .unknown, branch: nil)
        }
        let fromActions = await actionsStatus(entry, branch: branch)
        guard fromActions == .none else { return CIResult(status: fromActions, branch: branch) }
        return CIResult(status: await commitStatus(entry, branch: branch), branch: branch)
    }

    /// Default branch from REST metadata, for when GraphQL wouldn't say.
    private func defaultBranch(_ entry: CIFallback) async -> String? {
        do {
            let request = try makeRESTRequest("/repos/\(entry.namespace)/\(entry.name)")
            let detail: RESTRepoDetail = try await http
                .send(request, cacheKey: cacheKey(request))
                .decode(RESTRepoDetail.self)
            return detail.default_branch
        } catch {
            if !Log.isCancellation(error) {
                Log.network.error("Default branch lookup failed for \(entry.fullName, privacy: .public): \(Log.describe(error), privacy: .public)")
            }
            return nil
        }
    }

    /// Latest workflow run on a branch, as a CI state. Needs only
    /// `Actions: Read`, which fine-grained tokens *can* be given.
    private func actionsStatus(_ entry: CIFallback, branch: String) async -> CIStatus {
        do {
            let request = try makeRESTRequest("/repos/\(entry.namespace)/\(entry.name)/actions/runs", query: [
                .init(name: "branch", value: branch),
                .init(name: "per_page", value: "1"),
                // Runs triggered by pull requests say nothing about whether the
                // branch itself is green.
                .init(name: "exclude_pull_requests", value: "true"),
            ])
            let payload: WorkflowRuns = try await http
                .send(request, cacheKey: cacheKey(request))
                .decode(WorkflowRuns.self)
            guard let run = payload.workflow_runs.first else { return .none }
            return Self.mapWorkflowRun(status: run.status, conclusion: run.conclusion)
        } catch {
            if !Log.isCancellation(error) {
                Log.network.error("Actions status failed for \(entry.fullName, privacy: .public): \(Log.describe(error), privacy: .public)")
            }
            return .unknown
        }
    }

    /// Combined legacy commit status for a branch. Needs `Commit statuses:
    /// Read`, which fine-grained tokens can be given.
    private func commitStatus(_ entry: CIFallback, branch: String) async -> CIStatus {
        do {
            let ref = ProviderSupport.encodeSegment(branch)
            let request = try makeRESTRequest("/repos/\(entry.namespace)/\(entry.name)/commits/\(ref)/status")
            let payload: CombinedStatus = try await http
                .send(request, cacheKey: cacheKey(request))
                .decode(CombinedStatus.self)
            return Self.mapCombinedStatus(state: payload.state, count: payload.total_count ?? 0)
        } catch {
            if !Log.isCancellation(error) {
                Log.network.error("Commit status failed for \(entry.fullName, privacy: .public): \(Log.describe(error), privacy: .public)")
            }
            return .unknown
        }
    }

    /// The count is load-bearing, not the state. A commit with no statuses at
    /// all comes back as `state: "pending", total_count: 0` — reading the state
    /// alone would report "nothing ran" as "still running" forever.
    private static func mapCombinedStatus(state: String?, count: Int) -> CIStatus {
        guard count > 0 else { return .none }
        switch state?.lowercased() {
        case "success":        return .passing
        case "failure", "error": return .failing
        case "pending":        return .running
        default:               return .unknown
        }
    }

    /// GitHub Actions splits "is it done" from "how did it go", so both fields
    /// are needed: an in-flight run has no conclusion yet.
    private static func mapWorkflowRun(status: String?, conclusion: String?) -> CIStatus {
        if let status, status.lowercased() != "completed" { return .running }
        switch conclusion?.lowercased() {
        case "success":
            return .passing
        case "failure", "timed_out", "startup_failure":
            return .failing
        case "cancelled", "skipped", "neutral", "stale", "action_required":
            return .none
        case nil:
            return .running   // completed but unreported: treat as still settling
        default:
            return .unknown
        }
    }

    // MARK: - Review requests

    /// Open PRs anywhere that are waiting on this token's user, bucketed by
    /// repo. Cheaper and more accurate than asking each repo separately, since
    /// "requested from me" is a property of the viewer, not the repo.
    private func reviewRequestCounts() async throws -> [String: Int] {
        let response: Response<SearchPayload> = try await perform(
            Query.reviewRequests,
            variables: ["q": "is:open is:pr review-requested:@me archived:false"]
        )
        // GraphQL reports a permission failure on one field as a null value plus
        // an entry in `errors`, with the rest of the response intact and a 200
        // status. Treat a null search as the failure it is rather than as an
        // empty result set.
        guard let search = response.data.search else {
            let message = response.errors.map(\.message).joined(separator: " ")
            throw HTTPError.api(message.isEmpty
                ? "This token can't run the review-request search."
                : message)
        }
        var counts: [String: Int] = [:]
        for node in search.nodes {
            guard let name = node?.repository?.nameWithOwner else { continue }
            counts[name.lowercased(), default: 0] += 1
        }
        return counts
    }

    /// Maps a rollup state that actually arrived. A *missing* rollup is never
    /// routed here: it goes to the REST fallback instead, because "GitHub told
    /// me nothing" and "there is no CI" are different facts and only one of
    /// them is safe to show.
    private static func mapRollup(_ state: String) -> CIStatus {
        switch state.uppercased() {
        case "SUCCESS":            return .passing
        case "FAILURE", "ERROR":   return .failing
        case "PENDING", "EXPECTED": return .running
        default:                   return .unknown
        }
    }

    // MARK: - Transport

    private struct Response<T> {
        let data: T
        let errors: [GraphQLError]
    }

    /// Sends one GraphQL document. GitHub answers errors with HTTP 200 and an
    /// `errors` array, so a 200 is not on its own a success: a response with no
    /// `data` is an error, and a response with both is a partial success the
    /// caller gets to reconcile.
    private func perform<T: Decodable>(
        _ query: String,
        variables: [String: Any] = [:]
    ) async throws -> Response<T> {
        guard let endpoint else { throw HTTPError.badURL }

        var body: [String: Any] = ["query": query]
        if !variables.isEmpty { body["variables"] = variables }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw HTTPError.decoding("Could not encode the query.")
        }

        // No cache key: GraphQL is a POST, and GitHub does not honour
        // If-None-Match on it. Batching is what keeps this cheap instead.
        let response = try await http.send(request)

        // Decode the error list on its own first. GitHub answers a permission
        // or schema problem with HTTP 200 and a body whose `data` doesn't match
        // the shape we asked for — so decoding the payload throws, and if that
        // were the only attempt the server's explanation would be lost and the
        // user would get "unexpected response" for every distinct cause.
        let reported = (try? response.decode(ErrorsOnly.self))?.errors ?? []

        let envelope: Envelope<T>
        do {
            envelope = try response.decode(Envelope<T>.self)
        } catch {
            guard reported.isEmpty else { throw HTTPError.api(Self.join(reported)) }
            Log.network.error("GitHub response didn't decode: \(Log.describe(error), privacy: .public)")
            throw error
        }

        guard let data = envelope.data else {
            throw HTTPError.api(reported.isEmpty ? "GitHub returned no data." : Self.join(reported))
        }
        return Response(data: data, errors: envelope.errors ?? [])
    }

    private static func join(_ errors: [GraphQLError]) -> String {
        let message = errors.map(\.message).joined(separator: " ")
        return message.isEmpty ? "GitHub rejected the query." : message
    }

    /// REST base. GitHub.com serves it from a separate host; Enterprise mounts
    /// it under the instance at /api/v3.
    private var restBase: String {
        account.isSaaS ? "https://api.github.com" : "https://\(account.host)/api/v3"
    }

    private func makeRESTRequest(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(string: restBase + path) else { throw HTTPError.badURL }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw HTTPError.badURL }

        var request = URLRequest(url: url)
        // `Bearer`, never the legacy `token` scheme: GitHub rejects a
        // fine-grained token sent as `token …` with a 403, even for public
        // resources, which reads as a permissions problem and isn't one.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    /// ETags are per token: scope the cache key by account so rotating a token
    /// can't serve a 304 backed by the old token's view.
    private func cacheKey(_ request: URLRequest) -> String {
        "\(account.id.uuidString)|\(request.url?.absoluteString ?? "")"
    }
}

// MARK: - Queries

private enum Query {
    static let reviewRequests = """
    query($q: String!) {
      search(type: ISSUE, query: $q, first: 100) {
        nodes { ... on PullRequest { repository { nameWithOwner } } }
      }
    }
    """

    /// Shared by every aliased repository field in a highlights batch.
    /// `statusCheckRollup` folds both the legacy commit-status API and Actions
    /// check runs into one state, which is exactly the summary we want.
    static let highlightsFragment = """
    fragment H on Repository {
      nameWithOwner
      url
      defaultBranchRef {
        name
        target { ... on Commit { statusCheckRollup { state } } }
      }
      pullRequests(states: [OPEN]) { totalCount }
    }
    """
}

// MARK: - Wire types

private struct Envelope<T: Decodable>: Decodable {
    var data: T?
    var errors: [GraphQLError]?
}

/// The same envelope with `data` left unread, so the server's error list can be
/// recovered even when the payload doesn't match what the query asked for.
private struct ErrorsOnly: Decodable {
    var errors: [GraphQLError]?
}

private struct GraphQLError: Decodable {
    var message: String
    var type: String?
    /// Which field the error belongs to. For a highlights batch the first
    /// component is the repo's alias. Decoded leniently: GraphQL paths may
    /// contain list indices, and losing the attribution is better than failing
    /// to decode the response.
    var path: [String]?

    private enum CodingKeys: String, CodingKey { case message, type, path }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = (try? container.decode(String.self, forKey: .message)) ?? "Unknown error"
        type = try? container.decode(String.self, forKey: .type)
        path = try? container.decode([String].self, forKey: .path)
    }
}

private struct ViewerLogin: Decodable {
    var viewer: Viewer
    struct Viewer: Decodable { var login: String }
}

/// `repositoryOwner(login:)` is an interface, so `__typename` is what names the
/// concrete kind. Optional because GitHub returns null for a name it cannot
/// resolve rather than an error.
private struct RepositoryOwnerType: Decodable {
    var repositoryOwner: Owner?
    struct Owner: Decodable { var __typename: String }
}

/// A repo whose check-run rollup was refused, queued for the Actions fallback.
/// A struct rather than a tuple so it satisfies the Sendable requirement of the
/// concurrency helper without relying on tuple conformance.
private struct CIFallback: Sendable {
    let fullName: String
    let namespace: String
    let name: String
    /// nil when GraphQL wouldn't name the default branch; resolved over REST.
    let branch: String?
}

/// Result of the REST route: the state, plus whatever branch it was read from
/// so the row can show it even when GraphQL withheld the name.
private struct CIResult: Sendable {
    let status: CIStatus
    let branch: String?
}

/// `GET /repos/{owner}/{repo}` — used only for the default branch, which needs
/// nothing beyond Metadata: Read.
private struct RESTRepoDetail: Decodable {
    var default_branch: String?
}

/// `GET /repos/{owner}/{repo}/actions/runs`. Both fields are optional: the
/// payload shape varies across Enterprise versions and an unfinished run has no
/// conclusion.
private struct WorkflowRuns: Decodable {
    var workflow_runs: [Run]
    struct Run: Decodable {
        var status: String?
        var conclusion: String?
    }
}

/// `GET /repos/{owner}/{repo}/commits/{ref}/status`. `total_count` is kept
/// because `state` alone cannot distinguish "no statuses" from "pending".
private struct CombinedStatus: Decodable {
    var state: String?
    var total_count: Int?
}

/// A repository from `GET /user/repos`. Only the fields the picker shows —
/// GitHub's repository payload is enormous and mostly irrelevant here.
private struct RESTRepo: Decodable {
    var name: String
    var owner: Owner?
    var isPrivate: Bool
    /// Absent on older Enterprise versions, so optional rather than assumed.
    var archived: Bool?

    struct Owner: Decodable { var login: String }

    private enum CodingKeys: String, CodingKey {
        case name, owner, archived
        case isPrivate = "private"   // `private` is a Swift keyword
    }
}

private struct SearchPayload: Decodable {
    /// Optional because a token without the reach to run the search gets a null
    /// here alongside a field-level error, not an HTTP failure.
    var search: SearchResult?
    struct SearchResult: Decodable { var nodes: [Node?] }
    struct Node: Decodable {
        /// Absent for search hits that aren't pull requests (the inline
        /// fragment simply doesn't apply), hence optional.
        var repository: Repository?
        struct Repository: Decodable { var nameWithOwner: String }
    }
}

private struct RepoNode: Decodable {
    var nameWithOwner: String
    var url: URL?
    var defaultBranchRef: BranchRef?
    var pullRequests: TotalCount

    struct BranchRef: Decodable {
        var name: String
        var target: Target?
        struct Target: Decodable { var statusCheckRollup: Rollup? }
        struct Rollup: Decodable { var state: String }
    }
    struct TotalCount: Decodable { var totalCount: Int }
}

/// The aliased `r0`, `r1`, … fields of a highlights batch. The field names are
/// generated, so they can't be a fixed CodingKeys enum.
private struct RepoBatch: Decodable {
    var repos: [String: RepoNode]

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var repos: [String: RepoNode] = [:]
        for key in container.allKeys {
            // Null entries (repo not visible) are simply absent from the map;
            // the caller pairs the gap with the matching GraphQL error.
            if let node = try? container.decodeIfPresent(RepoNode.self, forKey: key) {
                repos[key.stringValue] = node
            }
        }
        self.repos = repos
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
