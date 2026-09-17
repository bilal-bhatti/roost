// RepoHighlights.swift — the per-repo numbers the popover shows. This is the
// common denominator across providers: whatever GitHub's GraphQL and GitLab's
// REST v4 return gets flattened into this before it reaches any view, so the UI
// never branches on provider.

import Foundation

/// CI state of the default branch, collapsed to the handful of outcomes worth
/// distinguishing at a glance.
enum CIStatus: String, Codable, Sendable {
    /// Latest run on the default branch succeeded.
    case passing
    /// Latest run failed or errored.
    case failing
    /// A run is in progress or queued.
    case running
    /// No CI configured, or the latest run was skipped/cancelled/manual.
    case none
    /// Not fetched yet, or the provider returned something unrecognised.
    case unknown

    /// SF Symbol for the state. Shape carries the meaning, so the badge is still
    /// readable without colour (see Views/DesignSystem.swift for the tint).
    var symbolName: String {
        switch self {
        case .passing: return "checkmark.circle.fill"
        case .failing: return "xmark.octagon.fill"
        case .running: return "clock.fill"
        case .none:    return "minus.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Spoken by VoiceOver and used in tooltips.
    var label: String {
        switch self {
        case .passing: return "Checks passing"
        case .failing: return "Checks failing"
        case .running: return "Checks running"
        case .none:    return "No checks"
        case .unknown: return "Check status unknown"
        }
    }
}

struct RepoHighlights: Codable, Hashable, Sendable {
    /// Open pull requests (GitHub) / merge requests (GitLab) on the repo.
    var openChangeRequests: Int = 0
    /// Of those, the ones waiting on *this account's user* to review.
    var reviewRequests: Int = 0
    /// False when the review-request lookup failed for this repo's account.
    /// Review requests are fetched account-wide in one call, so a failure there
    /// would otherwise read as a confident "0 reviews" — which is exactly the
    /// case the app exists to catch. A token scoped to one resource owner (any
    /// fine-grained PAT) commonly can't run that query, so this is not a rare
    /// edge case.
    var reviewRequestsAvailable: Bool = true

    var ci: CIStatus = .unknown
    var defaultBranch: String?
    /// Web URL, so clicking a row opens the right page on the right host.
    var url: URL?
    /// Set when this specific repo failed while its siblings succeeded — e.g.
    /// renamed, deleted, or the token lost access to it. Kept per-repo so one
    /// bad entry doesn't blank the whole account.
    var error: String?

    /// Nothing worth drawing attention to. A repo whose review count couldn't
    /// be fetched is never quiet — "we don't know" isn't "nothing to do".
    var isQuiet: Bool {
        error == nil && reviewRequests == 0 && reviewRequestsAvailable && ci != .failing
    }
}
