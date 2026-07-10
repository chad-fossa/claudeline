# Changelog

All notable changes to this project follow [Semantic Versioning](https://semver.org).
Each release corresponds to a `vMAJOR.MINOR.PATCH` git tag.

## v0.6.0 (2026-07-10)

### Fixes
- **macOS cross-profile usage leak**: Symptom: both profiles' statuslines showed the *last-login* account's numbers, even after v0.5.0 made the mismatch visible via `?`. Root cause: macOS Keychain has one slot for the Claude Max OAuth token (`Claude Code-credentials`), and `hooks/show-usage-limits.sh` read that slot unconditionally on Darwin regardless of which profile was active. `get_token()` now tries this profile's own `.credentials.json` FIRST on every platform; Keychain is a fallback used only when the file is absent.

### Added
- **claudeline-owned OAuth refresh**: New `refresh_token_grant()` POSTs the file's stored refresh token to Anthropic's OAuth endpoint and rotates the file in place (pre-POST `.bak`, tmp + `chmod 600` + atomic `mv`) when its access token expires — no dependency on Claude Code itself to keep the file usable. A failed refresh never falls back to Keychain silently: it drops a loud `/tmp/.claude_cred_refresh_failed_<account>` artifact and renders a dim/red `!` marker instead (see [marker table](README.md#cross-profile-identity-markers)).
- **`scripts/capture-profile-session.sh`**: New user-run script — copies the active Keychain session into the active profile's `.credentials.json` with a provenance stamp (`claudeline.captured_for_uuid`). Run it once per profile after `/login`; claudeline's owned refresh keeps the file usable after that, so logins become rare. See [Per-profile credentials (macOS)](README.md#per-profile-credentials-macos).
- **Provenance-gated `?` suppression**: The cross-profile `?` marker (introduced in v0.5.0) now clears once a profile's usage numbers are demonstrably its own — `token_source=="file"` AND the file's `claudeline.captured_for_uuid` matches this profile's account UUID. Any other case (no file, hand-captured file, mismatch) keeps `?` exactly as v0.5.0 did.
- **`scripts/test.sh`**: Extended with cases for file-first token resolution, `refresh_token_grant` (200 with/without refresh-token rotation, 500 leaves file/`.bak` untouched, `ACCOUNT_ASSUMED` refusal, lock contention), the capture script, and provenance-gated marker rendering (78 new cases).

### Known issues
- **Auto-capture is deferred to v0.6.1** — this release requires running `capture-profile-session.sh` manually once per profile after `/login`; automatically detecting a fresh login and re-capturing is planned for a follow-up release, pending a live soak of the owned-refresh path.
- **Concurrent logins across profiles remain a residual risk** — if both profiles authenticate around the same time, the shared Keychain slot can still serve a stale/wrong session to whichever profile's capture runs last, exactly as before v0.6.0. Re-run the capture script per profile to resolve.
- **A keychain-empty Claude Code login deletes the profile's `.credentials.json`** (binary-verified against claude 2.1.204) — the next hook invocation falls back to Keychain, `?` reappears. Re-run the capture script to restore file-first behavior.

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
