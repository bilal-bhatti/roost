// RepoRow.swift — one repository in the popover.
//
// Reading order matches how the row is scanned: CI state on the leading edge
// (the thing that is either fine or on fire), the repo and a plain-English
// detail line in the middle, counts on the trailing edge.

import SwiftUI

struct RepoRow: View {
    let repo: WatchedRepo
    let highlights: RepoHighlights?
    /// The owning account's provider vocabulary, so a GitLab row says MR, merge
    /// request and pipeline where a GitHub row says PR, pull request and checks.
    let lexicon: ProviderLexicon
    let action: () -> Void

    private var ci: CIStatus { highlights?.ci ?? .unknown }
    private var openCount: Int { highlights?.openChangeRequests ?? 0 }
    private var reviewCount: Int { highlights?.reviewRequests ?? 0 }

    var body: some View {
        RowButton(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.rowSpacing) {
                StatusGlyph(status: ci, hasError: highlights?.error != nil)

                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.fullName)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .rowText(.primary)
                    Text(detail)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .rowText(.secondary)
                }

                Spacer(minLength: Metrics.rowSpacing)

                if reviewCount > 0 {
                    ReviewBadge(count: reviewCount)
                }
                if openCount > 0 {
                    Text("\(openCount) \(lexicon.changeRequestAbbreviation)")
                        .font(.callout.monospacedDigit())
                        .rowText(.secondary)
                }
            }
        }
        .help(accessibilityLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    /// The secondary line. Leads with whatever most deserves attention rather
    /// than always printing the same fields in the same order.
    private var detail: String {
        if let error = highlights?.error { return error }
        guard highlights != nil else { return "Waiting for first check…" }

        if reviewCount > 0 {
            return "\(Formatting.count(reviewCount, "review")) waiting on you"
        }
        if ci == .failing {
            return "\(lexicon.ciNoun.capitalized) failing on \(highlights?.defaultBranch ?? "the default branch")"
        }
        // Never let a failed lookup masquerade as "nothing waiting on you".
        if highlights?.reviewRequestsAvailable == false {
            return "Review count unavailable"
        }
        if openCount > 0 {
            return Formatting.count(openCount, lexicon.changeRequestNoun)
        }
        return ci.label
    }

    private var accessibilityLabel: String {
        var parts = [repo.fullName]
        if let error = highlights?.error {
            parts.append(error)
            return parts.joined(separator: ", ")
        }
        if openCount > 0 {
            parts.append(Formatting.count(openCount, lexicon.changeRequestNoun))
        }
        if reviewCount > 0 {
            parts.append("\(Formatting.count(reviewCount, "review")) waiting on you")
        } else if highlights?.reviewRequestsAvailable == false {
            parts.append("review count unavailable, this token can't run the review search")
        }
        parts.append(ci.label)
        return parts.joined(separator: ", ")
    }
}

/// The leading status dot. An unreachable repo outranks its (now meaningless)
/// CI state, so the error symbol wins when both apply.
private struct StatusGlyph: View {
    let status: CIStatus
    let hasError: Bool

    @Environment(\.rowIsHighlighted) private var highlighted

    var body: some View {
        Image(systemName: hasError ? "exclamationmark.triangle.fill" : status.symbolName)
            .font(.body)
            .frame(width: 16, alignment: .center)
            // On a highlighted row the accent background swallows red and
            // green, so the glyph switches to the selection's text colour and
            // leans on its shape instead.
            .foregroundStyle(highlighted
                ? Color(nsColor: .alternateSelectedControlTextColor)
                : (hasError ? .orange : status.tint))
            .accessibilityHidden(true)
    }
}

/// Count of change requests waiting on this user — the one number Roost exists
/// to surface, so it gets the only filled shape in the row.
private struct ReviewBadge: View {
    let count: Int
    @Environment(\.rowIsHighlighted) private var highlighted

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(background))
            .foregroundStyle(foreground)
            .accessibilityHidden(true)
    }

    // Inverted on a highlighted row: an accent capsule on an accent background
    // would vanish.
    private var background: Color {
        highlighted
            ? Color(nsColor: .alternateSelectedControlTextColor)
            : Color.accentColor
    }

    private var foreground: Color {
        highlighted
            ? Color(nsColor: .selectedContentBackgroundColor)
            : Color(nsColor: .alternateSelectedControlTextColor)
    }
}
