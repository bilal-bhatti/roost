// GitLabTraits.swift — everything about GitLab that is not a network call.

import Foundation

struct GitLabTraits: ProviderTraits {
    let kind: ProviderKind = .gitlab
    let displayName = "GitLab"
    let symbolName = "arrow.triangle.branch"
    let defaultHost = "gitlab.com"
    /// GitLab stores token names as a plain string column and imposes no short
    /// cap the way GitHub does, so nothing Roost generates gets truncated.
    let tokenNameLimit = 255

    let lexicon = ProviderLexicon(
        identityNoun: "username",
        // Not "group": a GitLab project can sit directly under a user, and the
        // namespace of `acme/platform/api` is `acme/platform`, which is neither
        // one group nor an owner in GitHub's sense.
        namespaceNoun: "namespace",
        repoNoun: "project",
        repoNounPlural: "projects",
        changeRequestNoun: "merge request",
        changeRequestAbbreviation: "MR",
        ciNoun: "pipeline",
        tokenNoun: "access token"
    )

    /// One kind, so the settings form never shows a choice. Group access tokens
    /// are the second kind GitLab issues, and would be a second entry here.
    let credentials: [any Credential] = [GitLabPersonalCredential()]

    let missingRepoHint = """
        Rows marked with a ? are watched, but this token can't see them. They may \
        have been renamed, deleted, or moved out of its reach.
        """

    func makeProvider(account: Account, token: String, http: HTTPClient) -> Provider {
        GitLabProvider(account: account, token: token, http: http)
    }
}

/// GitLab's personal access token. Scoped to the person, not to a namespace,
/// which is why this credential has no scope field: an owner field here would be
/// inventing a setting the host does not have.
struct GitLabPersonalCredential: Credential {
    let id = "gitlab.personal"
    let displayName = "Personal access token"
    let promptPlaceholder = "glpat-…"
    let tokenPrefixes = ["glpat-"]

    let note = """
        GitLab issues one kind of personal access token. read_api is read-only: \
        it cannot modify anything on your account.
        """

    let permissionNote = """
        The link pre-ticks read_api, the least that lets Roost count open merge \
        requests, see which wait on you, and read the default branch's pipeline \
        status.
        """

    /// GitLab prefills from `name` and `scopes`. The /-/user_settings/ path
    /// replaced /-/profile/ in GitLab 16. GitLab does not require token names to
    /// be unique, but the same naming keeps a list of tokens across both
    /// providers readable.
    func creationURL(host: String, scopeName: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/-/user_settings/personal_access_tokens"
        components.queryItems = [
            .init(name: "name", value: GitLabTraits().tokenName(scope: scopeName)),
            .init(name: "scopes", value: "read_api"),
        ]
        return components.url
    }

    func reachSummary(for account: Account) -> String {
        let who = account.login.isEmpty ? "this token" : "@\(account.login)"
        return "A personal access token is scoped to the person: it reaches every namespace \(who) can see."
    }
}
