// Log.swift — diagnostics that survive being a background agent.
//
// Roost has no console and no window at launch, so a failure that happens
// before the user opens anything is otherwise invisible. Everything here goes
// to the unified log under the app's bundle id, readable live with:
//
//   log stream --predicate 'subsystem == "com.local.roost"' --level info
//
// Messages are marked `.public` because os.Logger redacts interpolated strings
// by default, which would reduce every entry to "<private>". Nothing logged
// here is sensitive: tokens are never passed to these calls, and the provider
// code builds its messages from HTTP status and server text only.
//
// Everything here logs at `.notice` or above, never `.info`: info-level
// messages live in a memory ring buffer and are usually gone before anyone
// runs `log show`, which makes them useless for "it did the wrong thing a
// minute ago" — the only kind of question this file exists to answer.

import Foundation
import os

enum Log {
    static let network = Logger(subsystem: "com.local.roost", category: "network")
    static let ui = Logger(subsystem: "com.local.roost", category: "ui")

    /// Human-readable text for any error, preferring LocalizedError's message
    /// over the Foundation default, which for our own enums is just the case
    /// name.
    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// True for the "the view went away" and "the account changed" cases, which
    /// are normal control flow rather than something to show or log.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
