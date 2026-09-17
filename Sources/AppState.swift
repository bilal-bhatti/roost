// AppState.swift — the single source of truth the whole UI observes.
//
// Holds the accounts, the watch list, the latest highlights, and the poll
// timer. Providers are created per refresh from (account + Keychain token);
// nothing here knows which provider a given account uses.

import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var accounts: [Account]
    @Published private(set) var watched: [WatchedRepo]

    /// Latest numbers, keyed by `WatchedRepo.id`. Keyed by the watch entry and
    /// not by repo path because the same repo watched through two accounts is
    /// two rows that can legitimately differ.
    @Published private(set) var highlights: [String: RepoHighlights] = [:]

    /// Account-wide failures (bad token, host unreachable, rate limited). Kept
    /// separate from per-repo errors so one dead account doesn't look like
    /// twenty dead repos.
    @Published private(set) var accountErrors: [UUID: String] = [:]

    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false

    @Published var refreshInterval: TimeInterval {
        didSet {
            guard refreshInterval != oldValue else { return }
            Store.refreshInterval = refreshInterval
            startPolling()
        }
    }

    @Published var showBadge: Bool {
        didSet { Store.showBadge = showBadge }
    }

    @Published private(set) var launchAtLogin: Bool

    private let http = HTTPClient()
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    /// Repo listings for the picker, cached for the session. Listing an account
    /// can be ten paginated requests, and re-running that every time the user
    /// switches tabs would be rude to both the server and the user.
    private var repositoryCache: [UUID: [RemoteRepo]] = [:]

    private init() {
        accounts = Store.accounts
        watched = Store.watched
        refreshInterval = Store.refreshInterval
        showBadge = Store.showBadge
        launchAtLogin = LoginItem.isEnabled
    }

    // MARK: - Derived state

    var isConfigured: Bool { !accounts.isEmpty }

    func repos(for account: Account) -> [WatchedRepo] {
        watched
            .filter { $0.accountID == account.id }
            .sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
    }

    func highlights(for repo: WatchedRepo) -> RepoHighlights? { highlights[repo.id] }

    func account(id: UUID) -> Account? { accounts.first { $0.id == id } }

    /// Total review requests across every watched repo — the one number worth
    /// putting in the menu bar itself.
    var totalReviewRequests: Int {
        watched.reduce(0) { $0 + (highlights[$1.id]?.reviewRequests ?? 0) }
    }

    var totalFailingChecks: Int {
        watched.reduce(0) { $0 + (highlights[$1.id]?.ci == .failing ? 1 : 0) }
    }

    /// One-line summary for the top of the popover.
    var summary: String {
        guard isConfigured else { return "No accounts yet" }
        guard !watched.isEmpty else { return "No repositories watched" }
        var parts: [String] = []
        if totalReviewRequests > 0 { parts.append(Formatting.count(totalReviewRequests, "review")) }
        if totalFailingChecks > 0 { parts.append("\(totalFailingChecks) failing") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        // Only claim everything is fine when everything was actually checked.
        let unknownReviews = watched.contains { highlights[$0.id]?.reviewRequestsAvailable == false }
        return unknownReviews ? "Reviews unavailable" : "All clear"
    }

    // MARK: - Accounts

    func addAccount(kind: ProviderKind) -> Account {
        let account = Account(kind: kind, label: kind.displayName)
        accounts.append(account)
        Store.accounts = accounts
        return account
    }

    /// Persists edited account fields. Changing the host invalidates anything
    /// cached for it, since the same path on a different host is a different repo.
    func update(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let previous = accounts[index]
        accounts[index] = account
        Store.accounts = accounts

        if previous.host != account.host || previous.kind != account.kind {
            repositoryCache[account.id] = nil
            invalidateCache(for: account.id)
            // The watch list was built against the old host; it means nothing on
            // the new one.
            watched.removeAll { $0.accountID == account.id }
            Store.watched = watched
            pruneHighlights()
        }
    }

    func removeAccount(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        watched.removeAll { $0.accountID == account.id }
        accountErrors[account.id] = nil
        repositoryCache[account.id] = nil
        Keychain.deleteToken(for: account.id)
        Store.accounts = accounts
        Store.watched = watched
        pruneHighlights()
        invalidateCache(for: account.id)
    }

    func token(for account: Account) -> String { Keychain.token(for: account.id) ?? "" }

    /// Returns false if the Keychain refused the write, so the form can say so
    /// instead of leaving the user believing a token was saved when it wasn't.
    @discardableResult
    func setToken(_ token: String, for account: Account) -> Bool {
        let stored = Keychain.setToken(token, for: account.id)
        if !stored {
            Log.network.error("Keychain write failed for \(account.host, privacy: .public)")
        }
        // Cached ETags were validated under the old token and say nothing about
        // what the new one can see.
        repositoryCache[account.id] = nil
        invalidateCache(for: account.id)
        return stored
    }

    struct VerifyOutcome: Sendable {
        let username: String
        /// The token works, but something about it looks wrong enough to say so.
        let warning: String?
    }

    /// Checks a token and stores the login it belongs to. Returns a message to
    /// show beside the account row — success or failure, but always something.
    func verify(_ account: Account) async -> Result<VerifyOutcome, Error> {
        let token: String
        switch Keychain.read(for: account.id) {
        case .success(let value): token = value
        case .failure(let error): return .failure(error)
        }
        let provider = ProviderFactory.make(account: account, token: token, http: http)
        do {
            let username = try await provider.verify()
            var updated = account
            updated.username = username
            // A blank owner means "not stated yet". Once the token's own user
            // is known, that is the right answer for the common case of
            // watching your own repositories — filling it in beats leaving a
            // field mysteriously empty for the user to guess at.
            if updated.owner.trimmingCharacters(in: .whitespaces).isEmpty {
                updated.owner = username
            }
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index] = updated
                Store.accounts = accounts
            }
            accountErrors[account.id] = nil
            return .success(VerifyOutcome(username: username, warning: await ownerWarning(for: updated, using: provider)))
        } catch {
            return .failure(error)
        }
    }

    /// Checks that a token scoped to someone else's account can actually reach
    /// them.
    ///
    /// This exists because of a specific, open GitHub bug: the token page's
    /// `target_name` parameter sets the Resource owner dropdown's *appearance*
    /// without setting the form, so a token can be created under the personal
    /// account while looking correct throughout. A fine-grained token's
    /// resource owner is fixed at creation, so the only cure is deletion —
    /// which makes catching it at verify time, rather than at the first
    /// confusing empty repo list, worth a request.
    private func ownerWarning(for account: Account, using provider: Provider) async -> String? {
        guard account.ownerNeedsSelecting else { return nil }
        let owner = account.owner.trimmingCharacters(in: .whitespaces)

        guard let repos = try? await provider.repositories() else { return nil }
        repositoryCache[account.id] = repos
            .sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }

        // Public repos are visible to every token regardless of scope, so only
        // a private one proves the token really reaches this owner.
        let reachesOwner = repos.contains {
            $0.isPrivate && $0.owner.caseInsensitiveCompare(owner) == .orderedSame
        }
        guard !reachesOwner else { return nil }

        return "Signed in as \(account.username), but this token can't see any private repository owned by \(owner) — its resource owner is probably your personal account. That can't be changed after the token is created: delete it and make a new one with Resource owner set to \(owner) on the page itself."
    }

    // MARK: - Repository picking

    /// Repos this account can see. Cached per session; `reload` forces a refetch
    /// after the user creates a new repo.
    func repositories(for account: Account, reload: Bool = false) async throws -> [RemoteRepo] {
        if !reload, let cached = repositoryCache[account.id] { return cached }
        // Throws KeychainError, not HTTPError.unauthorized: a token we couldn't
        // read locally has nothing to do with the server rejecting one.
        let token = try Keychain.read(for: account.id).get()
        let provider = ProviderFactory.make(account: account, token: token, http: http)
        let repos = try await provider.repositories()
            .sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
        repositoryCache[account.id] = repos
        return repos
    }

    func isWatching(_ repo: RemoteRepo, in account: Account) -> Bool {
        watched.contains { $0.accountID == account.id && $0.fullName == repo.fullName }
    }

    func setWatching(_ watching: Bool, repo: RemoteRepo, in account: Account) {
        let entry = WatchedRepo(accountID: account.id, repo: repo)
        if watching {
            guard !watched.contains(where: { $0.id == entry.id }) else { return }
            watched.append(entry)
        } else {
            watched.removeAll { $0.id == entry.id }
        }
        Store.watched = watched
        pruneHighlights()
        // The timer is only armed while there is something to poll, so ticking
        // the first repo has to start it.
        startPolling()
        refresh()
    }

    func unwatch(_ repo: WatchedRepo) {
        watched.removeAll { $0.id == repo.id }
        Store.watched = watched
        pruneHighlights()
        startPolling()
    }

    // MARK: - Refresh

    /// Fetches highlights for every account that has watched repos. Coalesces:
    /// a refresh requested while one is running is dropped rather than queued,
    /// since the queued one would fetch the same thing a moment later.
    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
            self?.refreshTask = nil
        }
    }

    private func performRefresh() async {
        guard !watched.isEmpty else {
            highlights.removeAll()
            accountErrors.removeAll()
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        var merged = highlights
        var errors: [UUID: String] = [:]

        for account in accounts {
            let repos = repos(for: account)
            guard !repos.isEmpty else { continue }

            let token: String
            switch Keychain.read(for: account.id) {
            case .success(let value):
                token = value
            case .failure(let error):
                errors[account.id] = Log.describe(error)
                Log.network.error("Token unavailable for \(account.host, privacy: .public): \(Log.describe(error), privacy: .public)")
                continue
            }

            // Review requests are looked up by login, and GitLab has no "@me"
            // shorthand for it. If the user pasted a token without pressing
            // Verify, resolve the login here rather than silently reporting
            // zero reviews forever.
            var account = account
            if account.username.isEmpty {
                if case .failure(let error) = await verify(account) {
                    errors[account.id] = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    continue
                }
                account = self.account(id: account.id) ?? account
            }

            let provider = ProviderFactory.make(account: account, token: token, http: http)
            do {
                let result = try await provider.highlights(for: repos)
                for repo in repos {
                    // A provider that returned nothing for a repo it was asked
                    // about is itself a per-repo failure worth showing.
                    merged[repo.id] = result[repo.fullName]
                        ?? RepoHighlights(error: "No data returned for this repository.")
                }
            } catch {
                guard !Log.isCancellation(error) else { continue }
                errors[account.id] = Log.describe(error)
                Log.network.error("Refresh failed for \(account.host, privacy: .public): \(Log.describe(error), privacy: .public)")
            }
        }

        highlights = merged
        accountErrors = errors
        lastRefresh = Date()
        pruneHighlights()
    }

    /// Drops highlights for repos that are no longer watched, so a stale row
    /// can't reappear if the repo is re-added later.
    private func pruneHighlights() {
        let live = Set(watched.map(\.id))
        highlights = highlights.filter { live.contains($0.key) }
    }

    private func invalidateCache(for accountID: UUID) {
        Task { await http.invalidateCache(prefix: accountID.uuidString) }
    }

    // MARK: - Polling

    /// Restarts the poll timer. Called at launch and whenever the interval
    /// changes; the in-flight sleep is cancelled so a change from an hour to a
    /// minute takes effect now rather than in an hour.
    func startPolling() {
        pollTask?.cancel()
        guard !watched.isEmpty else { return }
        let interval = refreshInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return  // cancelled
                }
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    // MARK: - Actions

    func open(_ repo: WatchedRepo) {
        if let url = highlights[repo.id]?.url {
            NSWorkspace.shared.open(url)
            return
        }
        // No URL yet (never refreshed, or the repo errored). The canonical web
        // path is the same shape on both providers, so build it from the host.
        guard let account = account(id: repo.accountID),
              let url = URL(string: "https://\(account.host)/\(repo.fullName)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LoginItem.set(enabled)
        launchAtLogin = LoginItem.isEnabled
    }

    private var settingsWindow: NSWindow?

    enum SettingsTab: Hashable {
        case accounts
        case repositories
        case general
    }

    /// Which pane the settings window shows. Published so callers can send the
    /// user to the tab that actually solves their problem — "no repositories
    /// watched" should open the picker, not the account list.
    @Published var settingsTab: SettingsTab = .accounts

    /// SwiftUI's Settings scene is unreliable for an LSUIElement agent (there is
    /// no app menu to open it from, and `showSettingsWindow:` is private API by
    /// another name), so Roost owns the window directly.
    func openSettings(tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        NSApp.activate(ignoringOtherApps: true)

        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(self))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Roost Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Size before placing: NSWindow(contentViewController:) starts at the
            // hosting view's fitting size, which SwiftUI hasn't measured yet.
            // Positioning first would centre the wrong rectangle and the window
            // would then grow from its top-left corner, landing off-centre.
            window.setContentSize(Metrics.settingsSize)
            settingsWindow = window
        }

        guard let window = settingsWindow else { return }
        // Place it only when it isn't already on screen, so reopening doesn't
        // yank a window the user deliberately moved.
        if !window.isVisible {
            window.setFrameOrigin(Self.settingsOrigin(for: window))
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Where the settings window should appear, computed at open time rather
    /// than stored. The menu bar item can be clicked on any display, and
    /// displays get attached, detached and rearranged between launches, so a
    /// remembered origin is wrong as often as it is right.
    ///
    /// Lands on the screen the pointer is on — that is the screen the user just
    /// clicked the menu bar on — centred horizontally and sitting slightly above
    /// the vertical centre, which is where macOS puts a freshly opened window.
    private static func settingsOrigin(for window: NSWindow) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        // No screens at all (headless session): leave the window where it is.
        guard let frame = screen?.visibleFrame else { return window.frame.origin }

        let size = window.frame.size
        let x = frame.minX + (frame.width - size.width) / 2
        // 60% of the leftover height goes below the window, so it reads as
        // "above centre" rather than sinking toward the Dock.
        let y = frame.minY + (frame.height - size.height) * 0.6

        // Clamp so an oversized window can never open with its title bar off
        // the top of the screen, where it couldn't be dragged back.
        return NSPoint(
            x: min(max(x, frame.minX), max(frame.minX, frame.maxX - size.width)),
            y: min(max(y, frame.minY), max(frame.minY, frame.maxY - size.height))
        )
    }
}
