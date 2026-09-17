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
}
