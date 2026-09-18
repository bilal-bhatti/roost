// ProviderKind.swift — which host an account belongs to, and nothing else.
//
// This used to be a 190-line enum carrying token URLs, permission matrices and
// three paragraphs of GitHub's own onboarding prose, switched on from the model
// layer and from four views. All of that now lives behind ProviderTraits in
// Sources/Providers/, one file per host.
//
// What is left is the part that genuinely belongs in the model: a small,
// stable, Codable tag naming which adapter serves an account. It has no
// behaviour and no `switch self`, and neither should anything that holds one.

import Foundation

enum ProviderKind: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case github
    case gitlab

    var id: String { rawValue }

    /// The adapter for this host. Everything a caller might once have switched
    /// on is a question to ask here instead.
    var traits: any ProviderTraits { ProviderRegistry.traits(for: self) }

    /// The host's own words for its own concepts. Reached through the traits
    /// like everything else; spelled out here because views ask for it often.
    var lexicon: ProviderLexicon { traits.lexicon }
}
