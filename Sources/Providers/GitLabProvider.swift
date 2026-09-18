// GitLabProvider.swift — gitlab.com and self-hosted GitLab, over REST v4.
//
// Why REST and not GitLab's GraphQL: self-hosted instances lag the SaaS schema
// by a long way, and GraphQL fields get renamed and deprecated between major
// versions. REST v4 is the stable surface every instance from 13.x onward
// speaks identically, which is what "supports self-hosted" has to mean.
//
// The cost is chattiness — GitLab has no way to ask about many projects at
// once, so a refresh is roughly two requests per repo plus one for review
// requests. That is why HTTPClient's conditional-request support matters here:
// GitLab sends ETags on these endpoints, unchanged resources come back as 304s
// with no body, and 304s don't count against the instance's rate limits.

import Foundation

struct GitLabProvider: Provider {
    let account: Account
    let token: String
    let http: HTTPClient

    // MARK: - Provider

    func verify() async throws -> String {
        let request = try makeRequest("/user")
        let user: User = try await http.send(request).decode(User.self)
        return user.username
    }

    func repositories() async throws -> [RemoteRepo] {
        var out: [RemoteRepo] = []
        // Ten pages of 100, same cap as the GitHub side: a member of a large
        // instance should not wait on an unbounded crawl.
        for page in 1...10 {
            let request = try makeRequest("/projects", query: [
                .init(name: "membership", value: "true"),
                .init(name: "order_by", value: "last_activity_at"),
                .init(name: "sort", value: "desc"),
                .init(name: "per_page", value: "100"),
                .init(name: "page", value: String(page)),
            ])
            let projects: [Project] = try await http.send(request).decode([Project].self)
            for project in projects {
                guard let split = ProviderSupport.splitPath(project.path_with_namespace) else { continue }
                out.append(RemoteRepo(
                    namespace: split.namespace,
                    name: split.name,
                    isPrivate: project.visibility != "public",
                    isArchived: project.archived ?? false
                ))
            }
            if projects.count < 100 { break }
        }
        return out
    }

    func highlights(for repos: [WatchedRepo]) async throws -> [String: RepoHighlights] {
        guard !repos.isEmpty else { return [:] }

        // 1. Resolve each watched path to a project. This is also where a
        //    renamed or deleted repo surfaces, and it gives us the default
        //    branch the pipeline query needs.
        let resolved = await ProviderSupport.mapConcurrently(repos) { repo in
            await resolve(repo)
        }

        // 2. One call for review requests across the whole account, bucketed by
        //    project id. "Requested from me" is a property of the user, so
        //    asking per project would be both slower and less accurate.
        //    nil means the call failed — kept distinct from "no reviews", since
        //    reporting zero when we couldn't ask defeats the point of the app.
        let reviewCounts = try? await reviewRequestCounts()

        // 3. Per project: open MR count and the default branch's last pipeline.
        let details = await ProviderSupport.mapConcurrently(resolved) { entry -> (String, RepoHighlights) in
            switch entry {
            case .failure(let fullName, let message):
                return (fullName, RepoHighlights(error: message))
            case .success(let fullName, let project):
                var highlights = RepoHighlights(
                    reviewRequests: reviewCounts?[project.id] ?? 0,
                    reviewRequestsAvailable: reviewCounts != nil,
                    defaultBranch: project.default_branch,
                    url: URL(string: project.web_url ?? "")
                )
                highlights.openChangeRequests = (try? await openMergeRequestCount(project.id)) ?? 0
                highlights.ci = await ciStatus(project: project)
                return (fullName, highlights)
            }
        }

        return Dictionary(details, uniquingKeysWith: { _, last in last })
    }

    // MARK: - Steps

    private enum Resolved: Sendable {
        case success(String, Project)
        case failure(String, String)
    }

    private func resolve(_ repo: WatchedRepo) async -> Resolved {
        do {
            let encoded = ProviderSupport.encodeSegment(repo.fullName)
            let request = try makeRequest("/projects/\(encoded)")
            let project: Project = try await http
                .send(request, cacheKey: cacheKey(request))
                .decode(Project.self)
            return .success(repo.fullName, project)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failure(repo.fullName, message)
        }
    }

    /// Open merge requests on a project. GitLab reports collection totals in the
    /// `X-Total` header, so asking for a single item is enough to learn the
    /// count — no need to download the merge requests themselves.
    private func openMergeRequestCount(_ projectID: Int) async throws -> Int {
        let request = try makeRequest("/projects/\(projectID)/merge_requests", query: [
            .init(name: "state", value: "opened"),
            .init(name: "per_page", value: "1"),
        ])
        let response = try await http.send(request, cacheKey: cacheKey(request))
        if let total = response.header("x-total").flatMap(Int.init) {
            return total
        }
        // Very large instances omit X-Total. Fall back to counting a full page,
        // which caps the reported number at 100 — fine for a glance badge.
        let fallback = try makeRequest("/projects/\(projectID)/merge_requests", query: [
            .init(name: "state", value: "opened"),
            .init(name: "per_page", value: "100"),
        ])
        let items: [MergeRequest] = try await http
            .send(fallback, cacheKey: cacheKey(fallback))
            .decode([MergeRequest].self)
        return items.count
    }

    private func reviewRequestCounts() async throws -> [Int: Int] {
        guard !account.login.isEmpty else { return [:] }
        let request = try makeRequest("/merge_requests", query: [
            .init(name: "scope", value: "all"),
            .init(name: "state", value: "opened"),
            .init(name: "reviewer_username", value: account.login),
            .init(name: "per_page", value: "100"),
        ])
        let items: [MergeRequest] = try await http
            .send(request, cacheKey: cacheKey(request))
            .decode([MergeRequest].self)

        var counts: [Int: Int] = [:]
        for item in items { counts[item.project_id, default: 0] += 1 }
        return counts
    }

    private func ciStatus(project: Project) async -> CIStatus {
        // No default branch means an empty project, not a broken pipeline.
        guard let branch = project.default_branch, !branch.isEmpty else { return .none }
        do {
            let request = try makeRequest("/projects/\(project.id)/pipelines", query: [
                .init(name: "ref", value: branch),
                .init(name: "order_by", value: "id"),
                .init(name: "sort", value: "desc"),
                .init(name: "per_page", value: "1"),
            ])
            let pipelines: [Pipeline] = try await http
                .send(request, cacheKey: cacheKey(request))
                .decode([Pipeline].self)
            guard let status = pipelines.first?.status else { return .none }
            return Self.mapPipelineStatus(status)
        } catch {
            return .unknown
        }
    }

    /// GitLab's pipeline vocabulary, collapsed to the four states worth showing.
    /// Cancelled, skipped and manual pipelines are "nothing ran", not failures —
    /// showing them red would train the user to ignore red.
    private static func mapPipelineStatus(_ status: String) -> CIStatus {
        switch status.lowercased() {
        case "success":
            return .passing
        case "failed":
            return .failing
        case "running", "pending", "created", "preparing", "waiting_for_resource", "scheduled":
            return .running
        case "canceled", "cancelled", "skipped", "manual":
            return .none
        default:
            return .unknown
        }
    }

    // MARK: - Transport

    /// Builds a request against `https://<host>/api/v4<path>`.
    ///
    /// `path` may already contain percent-encoded segments — GitLab addresses a
    /// project by its URL-encoded full path, e.g. `/projects/group%2Fapp`. It is
    /// assigned through `percentEncodedPath` precisely so URLComponents does not
    /// escape those `%` signs a second time.
    private func makeRequest(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = account.host
        components.percentEncodedPath = "/api/v4" + path
        if !query.isEmpty { components.queryItems = query }

        guard let url = components.url else { throw HTTPError.badURL }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// ETags are per token: scope the cache key by account so switching or
    /// rotating a token can't serve a 304 backed by the old token's view.
    private func cacheKey(_ request: URLRequest) -> String {
        "\(account.id.uuidString)|\(request.url?.absoluteString ?? "")"
    }
}

// MARK: - Wire types

private struct User: Decodable {
    var username: String
}

/// Only the fields Roost reads. GitLab's project payload is large and varies by
/// version, so everything optional stays optional.
private struct Project: Decodable, Sendable {
    var id: Int
    var path_with_namespace: String
    var default_branch: String?
    var web_url: String?
    var visibility: String?
    var archived: Bool?
}

private struct MergeRequest: Decodable {
    var project_id: Int
}

private struct Pipeline: Decodable {
    var status: String
}
