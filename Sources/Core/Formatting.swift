// Formatting.swift — the handful of user-facing strings that need care.

import Foundation

enum Formatting {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// "Updated just now" / "Updated 4 minutes ago". The "just now" case exists
    /// because RelativeDateTimeFormatter renders small gaps as "in 0 seconds",
    /// which reads as though something is about to happen.
    static func lastUpdated(_ date: Date?) -> String {
        guard let date else { return "Not checked yet" }
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 45 { return "Updated just now" }
        return "Updated \(relative.localizedString(for: date, relativeTo: Date()))"
    }

    /// "Every 5 minutes" for the interval picker.
    static func interval(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        switch minutes {
        case ..<1:  return "Every \(Int(seconds)) seconds"
        case 1:     return "Every minute"
        case 60:    return "Every hour"
        default:    return "Every \(minutes) minutes"
        }
    }

    /// Pluralises a count against its noun: `1 pull request`, `3 pull requests`.
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// Token prefixes worth keeping visible in a fingerprint. The prefix is the
    /// part that says *which kind* of token this is — the exact thing that gets
    /// mixed up between GitHub's two forms.
    private static let tokenPrefixes = [
        "github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "glpat-",
    ]

    /// A stored token, shown the way a credential should be: enough to
    /// recognise which one it is, never enough to use it.
    ///
    /// A fine-grained GitHub token is 93 characters. Rendered as 93 secure-field
    /// bullets it is a meaningless grey smear that overflows its field; rendered
    /// as `github_pat_••••4f9c` it is a name. Anything too short to cut safely
    /// becomes bullets only, since a 10-character secret has no middle to hide.
    static func maskedToken(_ token: String) -> String {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return "" }
        guard token.count >= 12 else { return String(repeating: "•", count: token.count) }
        let head = tokenPrefixes.first { token.hasPrefix($0) } ?? String(token.prefix(4))
        return "\(head)••••\(token.suffix(4))"
    }

    /// Spoken form of the same thing. VoiceOver reads a run of bullets one by
    /// one, which is both useless and endless.
    static func maskedTokenDescription(_ token: String) -> String {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 12 else { return "Token saved" }
        return "Token ending \(token.suffix(4)), \(token.count) characters"
    }
}
