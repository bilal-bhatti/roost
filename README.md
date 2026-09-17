# Roost

A macOS menu bar app that watches repositories across several GitHub and GitLab
accounts at once and tells you the three things worth knowing at a glance: how
many change requests are open, how many are waiting on **you**, and whether the
default branch is green.

Pure Swift compiled with `swiftc` - no Xcode project, no dependencies.

```
GitHub  (GraphQL) ─┐
                   ├─→  Roost (menu bar)  →  popover, grouped by account
GitLab  (REST v4) ─┘     URLSession + Keychain
```

Each account is a separate identity with its own token: "work GitLab" and
"personal GitHub" coexist, and a watched repo always records which account it is
read through.

## Build & install

```bash
./build-app.sh --install
```

Compiles `Sources/**/*.swift` into `Roost.app`, renders the icon, ad-hoc signs
it, and installs to `/Applications`. Omit `--install` to build into `./build/`
only. Re-run after editing `Sources/`, `Info.plist`, or the icon.

Requires macOS 14+ and the Command Line Tools (`xcode-select --install`). No
Apple Developer account needed.

### Keep the Keychain quiet across rebuilds (do this first)

Ad-hoc signing regenerates the app's code identity on every build, and macOS
keys per-app access to your stored tokens against that identity - so a rebuild
looks like a different app and the stored token becomes unreadable. Create a
stable self-signed identity once:

```bash
./setup-signing.sh        # one-time; no admin rights, no login-keychain prompts
./build-app.sh --install  # now signs with it automatically
```

It lives in its own keychain (`roost-signing.keychain-db`) and holds nothing but
this one local signing key. Remove it with `./setup-signing.sh --remove`. To sign
with your own identity instead (e.g. a Developer ID), set `SIGN_ID="…"` before
building.

## Configure

First launch opens **Settings** (also reachable from the menu bar icon, or ⌘,):

**Accounts** - add one per identity. Pick the provider, set the host, then get a
token. The token is stored in your login Keychain, never on disk. **Verify**
confirms it and resolves your login.

Roost only ever reads. It gets its own token rather than borrowing one from
another tool, so its access can be revoked on its own.

**Create Token…** opens the token form the provider recommends.

| Provider | What the link opens | Permissions | Read-only? |
|---|---|---|---|
| GitHub | Fine-grained token form | Metadata, Contents, Pull requests, Commit statuses, Actions - all Read-only | Yes |
| GitLab | Access token form | `read_api` | Yes |

Both links are prefilled. GitLab takes `name` and `scopes`; GitHub takes its
[PAT template URL](https://github.blog/changelog/2025-08-26-template-urls-for-fine-grained-pats-and-updated-permissions-ui/)
parameters (`name`, `description`, `expires_in`, and one per permission). The
token is requested with a **one-year** expiry (`expires_in=365`; the parameter
accepts 1-366 days, or `none`). When it lapses, Roost reports the account as
rejected - create a new one from the same link and paste it over the old.

Tokens are named `Roost (owner) YYYY-MM`, e.g. `Roost (khaplu) 2026-09`. GitHub
requires fine-grained token names to be unique per user, so the owner keeps two
accounts apart and the year-month keeps next year's replacement from colliding
with the token it replaces - which is still there at the moment you make it.
Long owner names are truncated to fit GitHub's 40-character cap; the `Roost`
prefix never is.

Two things to know about fine-grained tokens:

- One is bound to a **single resource owner**. Watching repos under an
  organisation means adding that organisation as its own account in Roost, with
  its own token, and setting that account's **Resource owner** field. The
  account list is built for exactly this.

  Two open GitHub bugs make org-scoped tokens fiddly, and they compound:
  `target_name` sets the Resource owner dropdown's *appearance* without setting
  the form state, so the token is created under your personal account unless you
  re-select the owner - and re-selecting it discards every other prefilled
  field. So for an org, pick the owner on the page **first**, then set the
  expiry and permissions by hand. Roost shows exactly what to set, selectable.

  A fine-grained token's resource owner is fixed at creation and cannot be
  changed, so getting it wrong means deleting the token. To catch that, **Verify**
  checks whether the token can actually see any private repository owned by the
  named owner, and warns when it can't.
- **GitHub does not offer fine-grained tokens a `Checks` permission at all** -
  it is GitHub App only. That breaks GraphQL's `statusCheckRollup`, which folds
  check runs and commit statuses into one value and refuses the whole field
  without it.

  `Contents: Read` is in the list for a related reason, and not for file
  contents: GraphQL refuses `defaultBranchRef` without it, and refuses it
  *silently* - null, no error. Roost no longer trusts a missing rollup either
  way, and re-reads the default branch from REST metadata when GraphQL won't
  name it, so a token without Contents still gets a CI state.

  When the rollup is missing, Roost reconstructs the state from the two
  APIs a fine-grained token *can* reach: `GET /repos/{o}/{r}/actions/runs`
  (`Actions: Read`), and if a repo has no workflow runs,
  `GET /repos/{o}/{r}/commits/{ref}/status` (`Commit statuses: Read`). Actions
  is tried first, so the common case is still one request.

  | CI reports as | Classic | Fine-grained |
  |---|---|---|
  | GitHub Actions | yes | yes, via Actions API |
  | Commit statuses (older third-party CI) | yes | yes, via Statuses API |
  | Check runs from a GitHub App (CircleCI, Buildkite, …) | yes | **no** |

  That last row is the real loss, and no PAT of any kind can close it - reading
  check runs requires a GitHub App installation token. If you depend on one of
  those integrations, use a classic token for that account and accept the write
  scope, or watch the repo through a GitHub App instead.

**Classic…** (GitHub only) opens the legacy classic-token form instead, with
`repo` and `read:org` pre-ticked. One classic token reaches every owner you can
see, which a fine-grained token cannot - but `repo` has no read-only form, so it
grants write access too. `read:org` only affects whether organisation-owned
repos appear in the picker.

If a token can't run the cross-owner review search, Roost says "Review count
unavailable" rather than reporting a confident zero.

For GitHub Enterprise or self-hosted GitLab, change the **Host** field - that is
the only difference. The API base URL follows from it.

**Repositories** - pick what to watch. The list is everything the token can see,
fetched once per launch; filter it and tick what you want.

**General** - how often to poll (1 minute to 1 hour), whether to show the pending
review count in the menu bar, and open-at-login.

## How the polling works

Roost refreshes on the interval you set, and whenever you open the menu.

- **GitHub** batches every watched repo for an account into a *single* GraphQL
  query, with one `search` field covering review requests across all of them. 20
  repos cost one request, not 60. GitHub meters GraphQL by query cost against a
  5,000-point hourly budget, which a batch like this barely dents.
- **GitLab** has no batched equivalent, so it costs roughly two requests per repo
  plus one for review requests. Every one of them is a conditional request: the
  client stores ETags and replays `If-None-Match`, so unchanged resources come
  back as empty 304s that don't count against the instance's rate limit.

The interval floor is one minute on purpose. Both providers meter per hour, and
polling faster buys no freshness you would notice.

## Source

| Path | Role |
|------|------|
| `Sources/Core/HTTPClient.swift` | **The only file that touches the network.** ETags, typed errors. |
| `Sources/Providers/Provider.swift` | The three-call seam every host plugs into. |
| `Sources/Providers/GitHubProvider.swift` | GitHub.com + Enterprise, GraphQL. |
| `Sources/Providers/GitLabProvider.swift` | gitlab.com + self-hosted, REST v4. |
| `Sources/AppState.swift` | Accounts, watch list, highlights, poll timer. |
| `Sources/Core/Keychain.swift` | Tokens, one item per account. |
| `Sources/Core/Store.swift` | Everything persisted to UserDefaults. |
| `Sources/Views/DesignSystem.swift` | Semantic type, colour and row highlighting. |
| `Sources/Views/` | The popover and the settings panes. |
| `build-app.sh` | Compiles, signs & installs. |

Adding a provider (Gitea, Bitbucket, …) is a case in `ProviderKind` plus one
file conforming to `Provider`. Nothing above that seam knows the difference.

## When something doesn't work

Roost is a background agent with no console, so failures go to the unified log:

```bash
log stream --predicate 'subsystem == "com.local.roost"' --level info
```

It logs each repository page as it loads, and the server's own wording on any
failure. Nothing sensitive goes through it - tokens are never passed to a log
call.

If an error mentions macOS blocking access to the saved token, the app was
rebuilt with a new code identity: run `./setup-signing.sh`, rebuild, and paste
the token again. That is a local Keychain problem, not a rejected token - the
provider never saw the request.

## Reset

- Accounts, watch list, preferences: `defaults delete com.local.roost`
- Tokens: `security delete-generic-password -s roost` (once per account)
