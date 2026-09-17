// DesignSystem.swift — the shared vocabulary every Roost view uses.
//
// The rules this file exists to enforce:
//
//  * Type comes from the semantic text styles (.body, .callout, .caption), never
//    from a hard-coded point size. Point sizes don't scale with the user's text
//    size setting and don't track the system font's optical adjustments.
//  * Colour comes from AppKit's semantic NSColors, never from a literal. A row
//    highlight is `selectedContentBackgroundColor` because that is what AppKit
//    paints selections with, so it follows the accent colour, appearance
//    changes, and the Increase Contrast setting for free.
//  * Meaning is never carried by colour alone. Every status has a distinct SF
//    Symbol shape and a spoken label alongside the tint.
//  * Motion is opt-out: anything animated checks Reduce Motion first.

import SwiftUI

enum Metrics {
    /// Wide enough for `owner/repository` plus badges without truncating the
    /// common case, narrow enough to stay a menu rather than a window.
    static let popoverWidth: CGFloat = 340
    /// The list scrolls past this; the popover never grows to fill the screen.
    static let listMaxHeight: CGFloat = 360

    /// Settings windows on macOS don't resize, so the panes are laid out for
    /// exactly this. Shared with AppState, which sizes the NSWindow to match —
    /// if the two drifted apart the window would open at the wrong size and
    /// then jump once SwiftUI measured its content.
    static let settingsSize = CGSize(width: 560, height: 440)

    static let contentInset: CGFloat = 12
    static let rowInset: CGFloat = 6
    static let rowSpacing: CGFloat = 8
    static let rowCorner: CGFloat = 6
    static let sectionSpacing: CGFloat = 4
}

extension CIStatus {
    /// Tint is an accent on top of the symbol's shape, never the only signal.
    var tint: Color {
        switch self {
        case .passing: return .green
        case .failing: return .red
        case .running: return .orange
        case .none:    return .secondary
        case .unknown: return .secondary
        }
    }
}

// MARK: - Row highlighting

private struct RowHighlightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a `RowButton` the pointer is over. Lets nested labels pick
    /// the right text colour for the highlighted background without each one
    /// tracking hover itself.
    var rowIsHighlighted: Bool {
        get { self[RowHighlightKey.self] }
        set { self[RowHighlightKey.self] = newValue }
    }
}

enum RowTextRole {
    case primary
    case secondary
}

private struct RowTextModifier: ViewModifier {
    let role: RowTextRole
    @Environment(\.rowIsHighlighted) private var highlighted
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(color)
    }

    private var color: Color {
        guard isEnabled else { return Color(nsColor: .tertiaryLabelColor) }
        // On a selected row AppKit switches the whole label stack to the
        // "alternate selected" colour; secondary text stays legible by dropping
        // opacity rather than by changing hue.
        if highlighted {
            let base = Color(nsColor: .alternateSelectedControlTextColor)
            return role == .primary ? base : base.opacity(0.8)
        }
        return role == .primary
            ? Color(nsColor: .labelColor)
            : Color(nsColor: .secondaryLabelColor)
    }
}

extension View {
    func rowText(_ role: RowTextRole) -> some View {
        modifier(RowTextModifier(role: role))
    }
}

/// A full-width, pointer-highlighted row — the popover's equivalent of a menu
/// item. Children read `\.rowIsHighlighted` to adapt their own colours.
struct RowButton<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.contentInset)
                .padding(.vertical, Metrics.rowInset)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: Metrics.rowCorner, style: .continuous)
                        .fill(highlighted ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                }
                .environment(\.rowIsHighlighted, highlighted)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.rowInset)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: highlighted)
    }

    private var highlighted: Bool { hovering && isEnabled }
}

/// A menu-style action row: aligned symbol column, then a title.
struct ActionRow: View {
    let title: String
    let systemImage: String
    var shortcut: KeyEquivalent?
    var modifiers: EventModifiers = .command
    let action: () -> Void

    var body: some View {
        let row = RowButton(action: action) {
            HStack(spacing: Metrics.rowSpacing) {
                Image(systemName: systemImage)
                    .font(.body)
                    .frame(width: 16, alignment: .center)
                Text(title)
                    .font(.body)
                Spacer(minLength: 0)
            }
            .rowText(.primary)
        }
        if let shortcut {
            row.keyboardShortcut(shortcut, modifiers: modifiers)
        } else {
            row
        }
    }
}
