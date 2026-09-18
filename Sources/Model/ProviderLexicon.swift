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
// The values themselves live with each host's other traits, in
// Sources/Providers/. This file is only the shape, so adding a noun makes the
// compiler name every host that has yet to supply it.
//
// What does *not* belong here: Roost's own vocabulary. "Account", "Display
// name", "Watching", "Verify" are this app's words for this app's concepts, and
// the popover stacks providers together where a shared noun is what makes the
// list scannable. Provider words belong inside one account's own section.
//
// Nor does anything about credentials. "Resource owner" reads like vocabulary,
// but it is a property of one *kind of token* rather than of the host, which is
// why it lives on Credential.scopeField and not here.

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

    /// "3 repositories" / "1 project", in the host's noun.
    func repoCount(_ n: Int) -> String {
        "\(n) \(n == 1 ? repoNoun : repoNounPlural)"
    }

    /// Used where there is no account selected yet and so no host whose words to
    /// borrow. Deliberately not GitHub's: defaulting to one provider's nouns is
    /// how "repositories" ends up labelling a pane that is about to show
    /// projects, and it reads as a bug to exactly the users it misnames.
    static let neutral = ProviderLexicon(
        identityNoun: "login",
        namespaceNoun: "namespace",
        repoNoun: "repository",
        repoNounPlural: "repositories",
        changeRequestNoun: "change request",
        changeRequestAbbreviation: "CR",
        ciNoun: "checks",
        tokenNoun: "token"
    )
}
