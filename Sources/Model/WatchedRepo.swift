// WatchedRepo.swift — a repository the user chose to monitor, plus the shape
// the repo picker lists candidates in.
//
// Both types say `namespace`, not `owner`. On GitHub the two are the same thing
// and "owner" would read fine; on GitLab the value is a namespace *path* that
// nests ("acme/platform" in "acme/platform/api"), and calling that an owner is
// simply wrong. The provider's own word for it reaches the UI through
// `ProviderLexicon.namespaceNoun`.

import Foundation

/// A repo on a remote host, as returned by a provider's listing call. Not
/// persisted; it only exists while the picker is open.
struct RemoteRepo: Identifiable, Hashable, Sendable {
    /// For GitHub this is the owner login (a user or an organisation). For
    /// GitLab it is the full namespace path, which can be nested, so never
    /// assume one level.
    var namespace: String
    var name: String
    var isPrivate: Bool
    var isArchived: Bool

    var fullName: String { "\(namespace)/\(name)" }
    var id: String { fullName }
}

/// A repo the user is monitoring, bound to the account it is read through. The
/// same repo watched via two accounts is two entries, by design: they can see
/// different things.
struct WatchedRepo: Identifiable, Codable, Hashable, Sendable {
    var accountID: UUID
    var namespace: String
    var name: String

    var fullName: String { "\(namespace)/\(name)" }
    var id: String { "\(accountID.uuidString):\(fullName)" }

    init(accountID: UUID, namespace: String, name: String) {
        self.accountID = accountID
        self.namespace = namespace
        self.name = name
    }

    init(accountID: UUID, repo: RemoteRepo) {
        self.init(accountID: accountID, namespace: repo.namespace, name: repo.name)
    }

    private enum CodingKeys: String, CodingKey {
        case accountID, namespace, name
    }

    /// The key this field was stored under before the rename. Its own enum so
    /// the synthesised `encode(to:)` never writes it back.
    private enum LegacyKeys: String, CodingKey {
        case owner
    }

    /// Hand-written so watch lists saved as `owner` survive the rename. Without
    /// this every user would open Roost to an empty list and have to re-tick
    /// everything, which is a rude way to ship a renamed field.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        accountID = try container.decode(UUID.self, forKey: .accountID)
        name = try container.decode(String.self, forKey: .name)
        namespace = try container.decodeIfPresent(String.self, forKey: .namespace)
            ?? legacy.decode(String.self, forKey: .owner)
    }
}
