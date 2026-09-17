// HTTPClient.swift — the only file that touches the network.
//
// Two things it does that a bare URLSession call would not:
//
//  1. Conditional requests. Roost polls on a timer, and most polls find nothing
//     changed. Every GET can carry a cache key; the client remembers the ETag
//     and replays `If-None-Match`, so an unchanged resource comes back as a 304
//     with no body. GitLab's REST v4 sends ETags on the endpoints we use, and a
//     304 does not consume its rate budget. (GitHub's GraphQL endpoint is a POST
//     and does not support conditional requests at all — it is metered by query
//     cost instead, which is why the GitHub provider batches every watched repo
//     into a single query rather than relying on caching.)
//
//  2. Typed errors. Callers need to tell "your token expired" from "you are
//     rate limited" from "that repo is gone" in order to say something useful
//     in the UI, and parsing English out of a response body is not that.

import Foundation

enum HTTPError: LocalizedError, Sendable {
    case badURL
    /// 401 — token missing, malformed, revoked or expired.
    case unauthorized
    /// 403 that is not a rate limit — usually a missing scope or SSO enforcement.
    case forbidden(String)
    /// Rate limited; `resetAt` is when the budget refills, when the server says.
    case rateLimited(Date?)
    case notFound
    case badStatus(Int, String)
    case transport(String)
    case decoding(String)
    /// The transport succeeded but the provider reported an error in the body
    /// (GraphQL does this with a 200).
    case api(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "That host doesn't form a valid URL."
        case .unauthorized:
            return "Token rejected. It may be expired or revoked."
        case .forbidden(let detail):
            return detail.isEmpty ? "Access denied. Check the token's scopes." : detail
        case .rateLimited(let resetAt):
            guard let resetAt else { return "Rate limited by the server." }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "Rate limited. Resets \(formatter.localizedString(for: resetAt, relativeTo: Date()))."
        case .notFound:
            return "Not found. The repository may have been renamed or deleted."
        case .badStatus(let code, let detail):
            return detail.isEmpty ? "Server returned HTTP \(code)." : "HTTP \(code): \(detail)"
        case .transport(let detail):
            return detail
        case .decoding(let detail):
            return "Unexpected response from the server. \(detail)"
        case .api(let detail):
            return detail
        }
    }

    /// Whether re-polling on the next tick could plausibly succeed. A bad token
    /// won't fix itself; a flaky network might.
    var isTransient: Bool {
        switch self {
        case .transport, .rateLimited, .badStatus: return true
        case .badURL, .unauthorized, .forbidden, .notFound, .decoding, .api: return false
        }
    }
}

/// A response with its headers flattened to a case-insensitive lookup. Headers
/// matter here: GitLab returns collection totals in `X-Total` rather than in the
/// body, which is how we count open merge requests without fetching them all.
struct HTTPResponse: Sendable {
    let data: Data
    let notModified: Bool
    private let headers: [String: String]   // keys pre-lowercased

    init(data: Data, notModified: Bool, headers: [String: String]) {
        self.data = data
        self.notModified = notModified
        self.headers = headers
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HTTPError.decoding(error.localizedDescription)
        }
    }
}

actor HTTPClient {
    private let session: URLSession
    /// cache key -> (etag, body, headers). Memory only: a cold start should see
    /// fresh data, and these payloads are small enough not to be worth a file.
    private var cache: [String: (etag: String, data: Data, headers: [String: String])] = [:]

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "Roost/1.0 (+https://github.com)"]
        // We do our own ETag bookkeeping; letting URLCache also cache would make
        // it ambiguous which layer served a given response.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    /// Drops every cached ETag. Called when an account's token changes, since
    /// the old token's 304s say nothing about what the new one can see.
    func invalidateCache(prefix: String) {
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
    }

    func send(_ request: URLRequest, cacheKey: String? = nil) async throws -> HTTPResponse {
        var request = request
        if let cacheKey, let entry = cache[cacheKey] {
            request.setValue(entry.etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // A cancelled request means the caller's Task was torn down — the
            // settings tab closed, the selected account changed. That is normal
            // control flow, not a failure, so it must not reach the UI as one.
            if error.code == .cancelled { throw CancellationError() }
            throw HTTPError.transport(Self.describe(error))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HTTPError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.transport("The server sent a non-HTTP response.")
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String { headers[key.lowercased()] = String(describing: value) }
        }

        switch http.statusCode {
        case 304:
            // Only reachable when we sent If-None-Match, so the entry exists.
            guard let cacheKey, let entry = cache[cacheKey] else {
                throw HTTPError.badStatus(304, "Unexpected Not Modified.")
            }
            return HTTPResponse(data: entry.data, notModified: true, headers: entry.headers)

        case 200...299:
            if let cacheKey, let etag = headers["etag"] {
                cache[cacheKey] = (etag, data, headers)
            }
            return HTTPResponse(data: data, notModified: false, headers: headers)

        case 401:
            throw HTTPError.unauthorized

        case 403:
            // GitHub signals an exhausted budget as a 403 with the remaining
            // count at zero; a 403 with budget left is a permissions problem.
            if headers["x-ratelimit-remaining"] == "0" {
                throw HTTPError.rateLimited(Self.resetDate(headers))
            }
            throw HTTPError.forbidden(Self.message(from: data) ?? "")

        case 404:
            throw HTTPError.notFound

        case 429:
            throw HTTPError.rateLimited(Self.resetDate(headers))

        default:
            throw HTTPError.badStatus(http.statusCode, Self.message(from: data) ?? "")
        }
    }

    // MARK: - Helpers

    /// Best-effort human message out of an error body. GitHub uses `message`,
    /// GitLab uses `message` or `error` and sometimes nests an array.
    private static func message(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let message = object["message"] as? String { return message }
        if let error = object["error"] as? String { return error }
        if let error = object["error_description"] as? String { return error }
        if let messages = object["message"] as? [String] { return messages.joined(separator: " ") }
        return nil
    }

    private static func resetDate(_ headers: [String: String]) -> Date? {
        // Seconds-from-now form (GitLab, and standard for 429s).
        if let retryAfter = headers["retry-after"], let seconds = Double(retryAfter) {
            return Date().addingTimeInterval(seconds)
        }
        // Absolute epoch form (GitHub, and GitLab's RateLimit-Reset).
        for key in ["x-ratelimit-reset", "ratelimit-reset"] {
            if let raw = headers[key], let epoch = Double(raw) {
                return Date(timeIntervalSince1970: epoch)
            }
        }
        return nil
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "No internet connection."
        case .timedOut:               return "The server took too long to respond."
        case .cannotFindHost:         return "Can't find that host. Check the host name."
        case .cannotConnectToHost:    return "Can't connect to that host."
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return "The server's TLS certificate wasn't trusted."
        default:                      return error.localizedDescription
        }
    }
}
