// WatchedRepo.swift — a repository the user chose to monitor, plus the shape
// the repo picker lists candidates in.

import Foundation

/// A repo on a remote host, as returned by a provider's listing call. Not
/// persisted; it only exists while the picker is open.
struct RemoteRepo: Identifiable, Hashable, Sendable {
    /// For GitHub this is the owner login. For GitLab it is the full namespace
    /// path, which can be nested ("group/subgroup"), so never assume one level.
    var owner: String
    var name: String
    var isPrivate: Bool
    var isArchived: Bool

    var fullName: String { "\(owner)/\(name)" }
    var id: String { fullName }
}

/// A repo the user is monitoring, bound to the account it is read through. The
/// same repo watched via two accounts is two entries, by design: they can see
/// different things.
struct WatchedRepo: Identifiable, Codable, Hashable, Sendable {
    var accountID: UUID
    var owner: String
    var name: String

    var fullName: String { "\(owner)/\(name)" }
    var id: String { "\(accountID.uuidString):\(fullName)" }

    init(accountID: UUID, owner: String, name: String) {
        self.accountID = accountID
        self.owner = owner
        self.name = name
    }

    init(accountID: UUID, repo: RemoteRepo) {
        self.init(accountID: accountID, owner: repo.owner, name: repo.name)
    }
}
