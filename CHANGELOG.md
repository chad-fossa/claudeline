# Changelog

All notable changes to this project follow [Semantic Versioning](https://semver.org).
Each release corresponds to a `vMAJOR.MINOR.PATCH` git tag.

## v0.7.0 (2026-07-10)

### Breaking

Both profiles' statuslines showed the same usage numbers because we fetched usage with a shared keychain token — v0.6.x's OAuth token came from the single shared macOS keychain slot (`Claude Code-credentials`), so whichever profile logged in last owned both bars. Claude Code ≥2.1.80 hands each session its own usage on stdin (`rate_limits.five_hour`/`.seven_day`) — verified live this session: work carried 5h=10%/7d=16% while personal carried 5h=14%/7d=7%, simultaneously, no auth — so we stopped fetching. The entire credential subsystem that fetched, refreshed, and cross-profile-captured that token is now deleted; cross-profile leakage becomes structurally impossible, since each bar can only render the usage its own session's stdin carries.

This is pre-1.0, so the removal below ships as a MINOR per this project's own versioning table — but it deletes installed files and changes the install layout, so treat it as breaking:

- **Deleted files**: `hooks/show-usage-limits.sh`, `scripts/capture-profile-session.sh`.
- **Deleted from `statusline-command.sh`**: `maybe_refresh_usage_cache`, `resolve_usage_refresh_hook`/`USAGE_REFRESH_HOOK`, `USAGE_CACHE_TTL_SECONDS`, `parse_iso_utc`, `unverifiable_marker` and its `?`/`!` markers, `token_source`/`provenance` cache fields.
- **Deleted from `install.sh`/`settings-example.json`**: the hook/capture-script downloads and the `hooks.SessionStart` wiring. Statusline + the `/usage` skill are the only artifacts installed now.
- **Markers**: `?` (unverifiable) and `!` (refresh-failed) are gone — there's no fetch-time credential state left to flag. The dim `=` marker (both profiles logged into the same account) stays, since it reads `.claude.json` directly and has nothing to do with usage fetching.
- **Cache schema**: mirrors stdin verbatim now — `{five_hour:{used_percentage,resets_at},seven_day:{...},fetched_at}`, with `resets_at` as a raw epoch int instead of an ISO string. An old v0.6.x-shaped cache is unrecognized and treated as absent (never renders a fabricated `0%`); the next stdin-carrying render overwrites it.
- **Requirements**: Claude Code ≥2.1.80, and a Claude.ai Pro or Max plan (usage limits don't apply otherwise). Usage is blank until the session's first API response — there's no pre-fetch anymore, so a brand-new session simply has nothing to show yet.
- **Migration**: `rm -f ~/.claude/hooks/show-usage-limits.sh ~/.claude*/scripts/capture-profile-session.sh` — stale caches from the old schema are auto-ignored, nothing else to do.
- [anthropics/claude-code#20553](https://github.com/anthropics/claude-code/issues/20553) (the single-keychain-slot issue that motivated the `?`/`!` markers in the first place) no longer affects claudeline — usage isn't fetched via Keychain anymore, so there's nothing left to leak.

### Fixes
- **PR number**: now read from stdin (`.pr.number`/`.pr.url`) when Claude Code already resolved it for the session, falling back to the existing `gh pr view` lookup only when stdin doesn't carry a PR.

## v0.6.1 (2026-07-10)

### Fixes
- **Identity probe response shape**: Captures always landed unverified — the `?` marker never cleared — because `capture-profile-session.sh`'s identity probe parsed `/api/oauth/profile`'s response as flat top-level `uuid`/`email` fields. Verified against the live endpoint, the real shape nests both under `account`: `{account: {uuid, email, ...}, organization: {...}, application: {...}}`. The parse now reads `.account.uuid` / `.account.email` first, with the old flat fields kept as harmless fallbacks.

## v0.6.0 (2026-07-10)

### Fixes
- **macOS cross-profile usage leak**: Symptom: both profiles' statuslines showed the *last-login* account's numbers, even after v0.5.0 made the mismatch visible via `?`. Root cause: macOS Keychain has one slot for the Claude Max OAuth token (`Claude Code-credentials`), and `hooks/show-usage-limits.sh` read that slot unconditionally on Darwin regardless of which profile was active. `get_token()` now tries this profile's own `.credentials.json` FIRST on every platform; Keychain is a fallback used only when the file is absent.

### Added
- **claudeline-owned OAuth refresh**: New `refresh_token_grant()` POSTs the file's stored refresh token to Anthropic's OAuth endpoint and rotates the file in place (pre-POST `.bak`, tmp + `chmod 600` + atomic `mv`) when its access token expires — no dependency on Claude Code itself to keep the file usable. A failed refresh never falls back to Keychain silently: it drops a loud `/tmp/claudeline-<uid>/.claude_cred_refresh_failed_<account>` artifact and renders a dim/red `!` marker instead (see [marker table](README.md#cross-profile-identity-markers)).
- **`scripts/capture-profile-session.sh`**: Copies the active Keychain session into the active profile's `.credentials.json` with a provenance stamp (`claudeline.captured_for_uuid`), then verifies the captured token's real owner against Anthropic's account-profile endpoint (one extra HTTPS call, made only at capture time — never per-render) before trusting it. A verified match stamps `claudeline.verified_account_uuid` + `verified_at`; a verified mismatch aborts with NO write, a loud stderr line naming both accounts' uuids/emails (never tokens), and a `/tmp/claudeline-<uid>/.claude_cred_capture_vetoed_<account>` artifact; a probe timeout/non-200/unparseable response still writes the file (usable) but without `verified_account_uuid` (`?` stays). Runnable manually (see [Manual capture](README.md#manual-capture-troubleshooting--recovery)) or invoked automatically — see auto-capture below. Acquires the same credential lock `refresh_token_grant` and auto-capture use around its read/probe/write section, so a manual run can't race an in-flight refresh — a held lock skips loudly (exit 1) rather than wait or corrupt the write. `install.sh` now downloads it to `$CLAUDE_DIR/scripts/` (both the curl-pipe and manual-install paths) so auto-capture works on a fresh install rather than needing a git checkout.
- **Auto-capture — `/login` is all you have to do**: `hooks/show-usage-limits.sh` now detects a fresh login in the active profile (a VALUE-CHANGE on `.claude.json`'s `oauthAccount.profileFetchedAt`, never file mtime — mtime churns on unrelated writes) and invokes the capture script automatically, so the manual step above is no longer required for the common case. Guarded by a two-sided corroboration window (default 30s, `CLAUDELINE_CAPTURE_WINDOW_SECS`) between that login stamp and the Keychain item's own modification time (read via `security find-generic-password` WITHOUT `-w` — metadata only): a login and a Keychain write more than the window apart get vetoed rather than risked, dropping `/tmp/claudeline-<uid>/.claude_cred_capture_vetoed_<account>` and a loud stderr line. `ACCOUNT_ASSUMED=1` refuses outright; a missing capture script skips loudly without ever failing the render. Runs inside the same lock `refresh_token_grant` uses, so it can't race an in-flight refresh — the hook hands that lock off to the capture script explicitly (`CLAUDELINE_CRED_LOCK_HELD=1`) rather than the child re-acquiring it. A captured or vetoed login is remembered, so the next render skips it; a transient failure (e.g. an unreadable Keychain entry) is not remembered, so the next render retries.
- **`?` suppression re-keyed to VERIFIED identity**: The cross-profile `?` marker (introduced in v0.5.0) now clears only when `token_source=="file"` AND the file's `claudeline.verified_account_uuid` exists and matches this profile's account UUID. `captured_for_uuid` alone (the capture script's own profile stamp, satisfiable by construction on a mis-capture) is forensics-only and can never suppress `?` — a hard condition surfaced by expert review of the original captured_for_uuid design. Files without a verified capture render `?` exactly as v0.5.0 did.
- **`scripts/test.sh`**: Extended with cases for file-first token resolution, `refresh_token_grant` (200 with/without refresh-token rotation, 500 leaves file/`.bak` untouched, `ACCOUNT_ASSUMED` refusal, lock contention, stale-lock reclaim), the capture script's identity probe (verified match / verified mismatch / probe-unreachable), auto-capture's trigger, two-sided veto window, and probe-storm guard, cache-provenance composition, and verified-identity marker rendering (197 cases total).

### Known issues
- **Auto-capture depends on `profileFetchedAt`**, which older Claude Code builds don't write to `.claude.json` — logins in those builds never trigger auto-capture and still need one [manual capture](README.md#manual-capture-troubleshooting--recovery) run (or an upgraded Claude Code) to retire `?`.
- **Concurrent logins across profiles remain a residual risk** — the corroboration window shrinks but can't fully close the race where both profiles authenticate within the same window; timestamp proximity on the single shared Keychain slot can't prove causal ownership between two independent per-profile logins. A vetoed capture is always visible (`/tmp/claudeline-<uid>/.claude_cred_capture_vetoed_<account>`), never silent.
- **A keychain-empty Claude Code login deletes the profile's `.credentials.json`** (binary-verified against claude 2.1.204) — the next hook invocation falls back to Keychain, `?` reappears until the next successful auto-capture (or a manual capture run).
- **Upgrading from a pre-auto-capture install changes nothing until your next `/login`** — auto-capture triggers on a login *event* (a `profileFetchedAt` value-change), not on install; an already-logged-in profile keeps reading from Keychain (or a stale file) until you log in again in that profile.
- **A Keychain-owning profile's captured session can periodically fail refresh if Anthropic rotates refresh tokens out from under it** — claudeline's own refresh only knows the token it captured; if Anthropic's backend invalidates it independently (token rotation, a revoke, etc.) the next refresh attempt fails loudly (`!`, per the marker table) rather than silently falling back. A fresh `/login` re-captures and clears it. A deeper fix (identity-anchored capture that re-verifies and re-captures automatically on this class of failure) is planned but not built yet.
- **`/usage`'s synchronous worst case is ~15s** — if a login-capture, a refresh, and the usage fetch all end up needing to happen within the same invocation (a `/usage` run right after a fresh login on an expired file), the three network calls run sequentially, each bounded by its own 5s `--max-time`.
- **Provenance staleness also runs in reverse** — a `.credentials.json` swapped for a different, mismatched identity right after a `verified_match` was cached can leave `?` incorrectly *suppressed* for up to the 300s cache TTL, mirroring the already-documented forward case (a just-verified capture keeping `?` up for up to 300s). Both self-correct at the next cache write; see [marker table](README.md#cross-profile-identity-markers).

## v0.5.0 (2026-07-06)

### Fixes
- **Cross-profile cache/lock collisions**: Symptom: personal statusline showed work's usage numbers. The PR-view cache, branch cache, and lock files were keyed only by repo name, so work and personal sessions in the same repo clobbered each other's PR data; the usage cache and account label used inconsistent detection logic between `statusline-command.sh` and `hooks/show-usage-limits.sh`. Consolidated account detection into one `detect_account()` (kept in sync across both files) and keyed PR cache/branch/lock files by account as well as repo name.
- **Account detection distinguishes unset vs empty `CLAUDE_CONFIG_DIR`**: Previously an unset var and an explicit `CLAUDE_CONFIG_DIR=""` were treated the same, silently assuming "work". Now an unset `CLAUDE_CONFIG_DIR` is flagged as an assumption and the account label renders dimmed to signal it wasn't explicitly detected.
- **Hook path is profile-aware**: `USAGE_REFRESH_HOOK` previously always pointed at `$HOME/.claude/hooks/show-usage-limits.sh` regardless of active profile. Now resolves the active `CLAUDE_CONFIG_DIR`'s own hook first, falling back to the work install if the profile doesn't have one.
- **`install.sh` honors `CLAUDE_CONFIG_DIR`**: The installer previously always targeted `~/.claude`. It now installs into `$CLAUDE_CONFIG_DIR` when set, so a personal profile can be installed directly instead of only via symlinking from work.

### Added
- **Cross-profile identity markers**: Since macOS Keychain has only one slot for the Claude Max OAuth token, both profiles can end up silently sharing (or worse, mismatching) logins. claudeline now surfaces this instead of rendering silently wrong/unverifiable numbers: a dim `=` after the account label when both profiles share the same login, a dim `?` after the usage segment (macOS only) when the profiles have different logins and the shown numbers can't be verified to belong to the active one, and a dimmed account label when the account was assumed rather than explicitly detected. See [Cross-profile identity markers](README.md#cross-profile-identity-markers).
- **`scripts/test.sh`**: Smoke-test harness validating account detection, cache keying, and marker rendering (36 cases).

### Known issues
- **macOS Keychain single-slot limitation is unchanged** — [anthropics/claude-code#20553](https://github.com/anthropics/claude-code/issues/20553) still means both profiles can end up authenticated as the same account, or a stale token can serve the wrong profile's numbers, on macOS. This release does not fix that; it makes the mismatched/unverifiable state *visible* via the `?` marker instead of silently rendering the wrong numbers. A token-identity probe that would auto-detect the mismatch (rather than infer it from `.claude.json` account UUIDs) is descoped pending verification of a suitable API endpoint.

## v0.4.0 (2026-05-24)

### Features
- **Linux support**: Statusline and hook now run on Linux (tested on Debian 13 / aarch64). Cross-platform `date` helpers (`parse_iso_utc` / `fmt_epoch`) abstract BSD vs GNU `date` flags, and the hook reads OAuth from `$CLAUDE_CONFIG_DIR/.credentials.json` on Linux instead of Keychain. Multi-account selection continues to work — each `CLAUDE_CONFIG_DIR` has its own credentials file.
- **Installer cross-platform**: `install.sh` now accepts both `Darwin` and `Linux` from `uname` instead of erroring out on non-macOS.
- **Background usage-cache refresh**: Statusline renders now spawn a background refresh of the usage-limits cache when it's older than 5 minutes, so stats stay current without waiting for the next `SessionStart`. A short-lived lock (`/tmp/.claude_usage_refresh_lock_<account>`) prevents stampede when multiple renders fire close together; the current render always uses on-disk data (zero latency cost), and the refreshed numbers appear on the next render.

### Fixes
- Replace `stat -f%m` with a `file_mtime` helper that uses `stat -c%Y` on Linux. Previously the PR/branch and lock-age caches always reported zero age on Linux, defeating the 10-minute cache.

## v0.3.1 (2026-05-10)

### Fixes
- **Hook keychain lookup**: Read the Claude Max OAuth token from the default `Claude Code-credentials` keychain entry instead of trying to find a hashed `Claude Code-credentials-{hash}` entry per `CLAUDE_CONFIG_DIR`. The hashed entry exists but only holds `mcpOAuth` tokens with empty `accessToken` fields — the previous logic matched an empty MCP token and emitted "Could not get credentials". Symptom: usage stats missing on the personal account, fine on work. Anchors the grep on `claudeAiOauth.accessToken` so MCP tokens can't shadow it.
- **/usage skill**: Pipe empty JSON to the hook when invoked manually so it doesn't hang on stdin. Update description to reflect per-account cache paths.

### Docs
- Clarify in the `/usage` skill that it refreshes whichever account is currently active.

### Known issues
- macOS Keychain still has only one slot for the Claude Max OAuth token (`Claude Code-credentials`), so switching accounts via `/login` overwrites the previous account's token. This is upstream — see [anthropics/claude-code#20553](https://github.com/anthropics/claude-code/issues/20553).

## v0.3.0 (2026-03-13)

### Features
- **Multi-account support**: Run separate work and personal Claude Code accounts on the same machine with per-account usage caching and `[W]`/`[P]` indicators
- **Customizable account labels**: Set `CLAUDE_ACCOUNT_WORK_LABEL`, `CLAUDE_ACCOUNT_PERSONAL_LABEL`, and color env vars in `.zshrc`

### Fixes
- **Token extraction**: Switch from `jq` to `grep` for extracting OAuth tokens from Keychain — fixes breakage when MCP OAuth tokens bloat the credentials JSON beyond Keychain's output limit
- **PR rate limiting**: Add lock guard to prevent concurrent `gh pr view` calls from piling on during rapid statusline renders. Increase PR cache TTL from 120s to 600s.
- **Usage cache mismatch**: Default to "work" account when `transcript_path` isn't available, instead of looking for a non-existent "default" cache file

## v0.2.0 (2026-03-10)

### Features
- **Worktree detection**: Show `⎇worktree-name` prefix when working in a git worktree instead of the repo name
- **Context window**: Use pre-calculated `used_percentage` from Claude Code JSON input when available, with manual token calculation as fallback

### Fixes
- **Usage limits time format**: Show 12h AM/PM (e.g., `3pm`) instead of 24h format for 5-hour reset time
- **Timezone parsing**: Strip both fractional seconds and timezone suffix from reset timestamps for reliable parsing

## v0.1.0 (2025-01-10)

- Initial release
