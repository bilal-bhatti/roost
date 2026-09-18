// ProviderLexicon.swift — each provider's own words.
//
// Roost talks to hosts that model the same shapes under different names, and the
// honest thing is to use each host's name for its own thing rather than invent a
// neutral third word nobody uses. GitHub has owners (users and organisations)
// holding repositories with pull requests and checks; GitLab has namespaces
// (users and nested groups) holding projects with merge requests and pipelines.
// A GitLab user who is told their "repositories" have "pull requests" has to
// translate every sentence back.
//
// `changeRequestNoun` and `changeRequestAbbreviation` already proved the pattern
// on ProviderKind; this type finishes the job in one place instead of scattering
// more per-provider switches through the views.
//
// What does *not* belong here: Roost's own vocabulary. "Account", "Display
// name", "Watching", "Verify" are this app's words for this app's concepts, and
// the popover stacks providers together where a shared noun is what makes the
// list scannable. Provider words belong inside one account's own section.

import Foundation

struct ProviderLexicon: Sendable {
    /// What the host calls the name you sign in with.
    let identityNoun: String
    /// What the host calls the thing before the slash in `acme/api`.
    let namespaceNoun: String
    let repoNoun: String
    let repoNounPlural: String
    let changeRequestNoun: String
    let changeRequestAbbreviation: String
    /// What the host calls the thing that goes green or red.
    let ciNoun: String
    /// What the host calls the credential on its own settings pages.
    let tokenNoun: String
    /// Label for the field naming what a credential is scoped to, or nil when
    /// the provider has no such concept. GitHub fine-grained tokens have one
    /// ("Resource owner"); GitLab personal access tokens do not.
    let scopeFieldLabel: String?
    /// Prompt for that field. Only shown when `scopeFieldLabel` is non-nil.
    let scopeFieldPrompt: String

    static let github = ProviderLexicon(
        identityNoun: "login",
        namespaceNoun: "owner",
        repoNoun: "repository",
        repoNounPlural: "repositories",
        changeRequestNoun: "pull request",
        changeRequestAbbreviation: "PR",
        ciNoun: "checks",
        tokenNoun: "personal access token",
        scopeFieldLabel: "Resource owner",
        scopeFieldPrompt: "your login, or an organisation"
    )

    static let gitlab = ProviderLexicon(
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
        tokenNoun: "access token",
        // A personal access token is scoped to the person, not to a namespace.
        // Group access tokens are, and would set this when Roost learns them.
        scopeFieldLabel: nil,
        scopeFieldPrompt: "group path"
    )

    /// "3 repositories" / "1 project", in the host's noun.
    func repoCount(_ n: Int) -> String {
        "\(n) \(n == 1 ? repoNoun : repoNounPlural)"
    }
}

extension ProviderKind {
    var lexicon: ProviderLexicon {
        switch self {
        case .github: return .github
        case .gitlab: return .gitlab
        }
    }
}
