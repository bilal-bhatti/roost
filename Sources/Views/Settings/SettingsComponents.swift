// SettingsComponents.swift — the small pieces both settings panes share.
//
// These exist for one reason: the panes had accumulated paragraphs of caption
// text under every field. All of it was true and most of it was needed *once*,
// by someone setting an account up for the first time. Left on screen it turns
// a four-field form into an essay, and the fields — the thing people actually
// came for — sink below the fold. So the prose moves into `InfoButton`, the
// flow gets numbered by `StepHeader`, and the fields get the room back.

import SwiftUI
import AppKit

/// A ⓘ button that parks an explanation off-screen until it is asked for.
struct InfoButton: View {
    let title: String
    let message: String

    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    // Selectable: some of these name permissions that have to be
                    // ticked by hand on a web page, and retyping them from a
                    // screenshot is how they get mistyped.
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
        .accessibilityLabel("About \(title)")
        .help(title)
    }
}

/// A numbered section heading. Setting an account up is a sequence — say where,
/// make a token, paste it back — and numbering is what keeps the three boxes
/// from reading as three unrelated ones you might fill in any order.
struct StepHeader<Accessory: View>: View {
    let number: Int
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)
            Text(title)
            accessory()
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title)")
    }
}

extension StepHeader where Accessory == EmptyView {
    init(_ number: Int, _ title: String) {
        self.init(number: number, title: title) { EmptyView() }
    }
}

/// The filter field used above both long lists. AppKit's search field has no
/// SwiftUI equivalent outside `.searchable`, which insists on a navigation
/// container neither of these panes has.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: focused ? .controlAccentColor : .separatorColor))
        }
        .onTapGesture { focused = true }
    }
}

/// The +/− strip under a list — the standard macOS affordance for editing a
/// collection, which is why the buttons live there and not in a toolbar.
struct AddRemoveBar<AddContent: View>: View {
    let removeHelp: String
    let canRemove: Bool
    let remove: () -> Void
    @ViewBuilder var addMenu: () -> AddContent

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                addMenu()
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help("Add an account")

            Button(action: remove) {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .frame(width: 24)
            .disabled(!canRemove)
            .help(removeHelp)

            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
