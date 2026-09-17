// Store.swift — everything Roost persists, in one place.
//
// Split by sensitivity: account metadata and the watch list are plain
// UserDefaults (`com.local.roost`), API tokens are in the Keychain and never
// appear here. Reset the non-secret half with:
//
//   defaults delete com.local.roost

import Foundation

enum Store {
    private enum Keys {
        static let accounts = "accounts"
        static let watched = "watchedRepos"
        static let refreshInterval = "refreshIntervalSeconds"
        static let showBadge = "showBadgeInMenuBar"
    }

    /// Poll intervals offered in Settings. Floored at a minute on purpose: both
    /// providers rate-limit per hour, and anything faster buys no freshness a
    /// person would notice while burning budget the rest of the day needs.
    static let refreshIntervalChoices: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600]
    static let defaultRefreshInterval: TimeInterval = 300

    static var accounts: [Account] {
        get { decode([Account].self, key: Keys.accounts) ?? [] }
        set { encode(newValue, key: Keys.accounts) }
    }

    static var watched: [WatchedRepo] {
        get { decode([WatchedRepo].self, key: Keys.watched) ?? [] }
        set { encode(newValue, key: Keys.watched) }
    }

    static var refreshInterval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: Keys.refreshInterval)
            // 0 means "never set", not "poll continuously".
            guard stored > 0 else { return defaultRefreshInterval }
            return max(refreshIntervalChoices.first ?? 60, stored)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.refreshInterval) }
    }

    static var showBadge: Bool {
        get { UserDefaults.standard.object(forKey: Keys.showBadge) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.showBadge) }
    }

    // MARK: - Helpers

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
