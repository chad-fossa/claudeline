---
name: cache-and-account-contract
description: v0.7.0 stdin-sourced usage-cache schema, account-detection rule, and PR-cache keying (post credential-subsystem deletion)
metadata:
  type: reference
---

Confirmed against code 2026-07-10 (branch cf/v0.7.0-stdin-rate-limits @ 2c32e0b). This entry replaces the pre-v0.7.0 version wholesale — the OAuth-fetch subsystem it described (`hooks/show-usage-limits.sh`, `maybe_refresh_usage_cache`, TTL, `get_token()`) is deleted. See [[v070-stdin-cache-verification]] for the full ship-gate writeup.

**Source of usage data**: Claude Code ≥2.1.80 hands each session its own usage on the statusline's stdin — `.rate_limits.five_hour.{used_percentage,resets_at}` / `.seven_day.{...}`. `get_usage_limits()` (statusline-command.sh:153-224) reads it straight off `$INPUT`. No fetch, no OAuth, no hook.

**Cache file**: `${RUNTIME_DIR}/.claude_usage_limits_${ACCOUNT_ID}.json` (statusline-command.sh:115, `RUNTIME_DIR=/tmp/claudeline-$(id -u)`, not bare `/tmp` — see `verify_runtime_dir`). Written inline and synchronously by `write_usage_cache()` (statusline-command.sh:117-129) whenever stdin carries `rate_limits` — no lock, no background spawn (deliberate per spec; a co-tenant-owned `RUNTIME_DIR` skips the write via `RUNTIME_DIR_SAFE`, same guard as before). Read back by `get_usage_limits()` only when stdin lacks `rate_limits` (pre-first-response renders).

**Schema** mirrors stdin verbatim: `{"five_hour":{"used_percentage":<num>,"resets_at":<epoch int>},"seven_day":{...},"fetched_at":<epoch int>}`. `resets_at` is a raw epoch int now, not the ISO string the old schema held — `parse_iso_utc` is gone, `fmt_epoch` formats the epoch directly (`+%-I%p` lowercased for 5h, `+%m/%d` for 7d).

**Staleness = per-window rollover, not TTL.** `USAGE_CACHE_TTL_SECONDS` and `maybe_refresh_usage_cache()` are deleted. Each window's `resets_at` is checked independently against `now` (statusline-command.sh:204-215); an expired 5h window drops only its own segment, 7d renders independently. Anti-fabrication guard survives: cache read gates on `fetched_at` being non-empty/non-null (statusline-command.sh:194) — an old v0.6.x-shaped cache (`utilization` instead of `used_percentage`, ISO `resets_at`) folds to empty via the `// ""` jq defaults and is treated as absent, never a fabricated `0%`. A legit `0%` is distinguishable from absent because jq's `tostring` on `0` yields the non-empty string `"0"`, not `""` — both the stdin-presence check and the cache-read `five_pct` check test for empty-string/`"null"`, not falsiness, so `0` passes through and renders `0%` correctly (verified statusline-command.sh:170, 195, 207).

**Cache write is not atomic** (no tmp+mv, no lock) — a kill mid-`jq -n > file` write can leave a truncated/partial-JSON cache. Not a live bug: a truncated JSON file makes the next render's `jq -r` read fail/produce empty output, which folds to an empty `fetched_at` and is caught by the same anti-fabrication guard (render nothing, not garbage). Flagged as fragile-but-safe-by-construction rather than genuinely robust — an explicit tmp+mv would remove the reliance on jq's failure mode lining up with the guard's empty-string check.

**Account detection rule** — now the SOLE copy, no cross-file sync concern:
- statusline-command.sh:50-60 (`detect_account()`)

Rule unchanged: `CLAUDE_CONFIG_DIR` substring-matches `"claude-personal"` → `ACCOUNT_ID="personal"`; anything else, including unset, → `ACCOUNT_ID="work"` (default-to-work trap, same as always).

**PR cache keying** — unchanged from the earlier fix, still account-keyed: `get_pr_number()` (statusline-command.sh:328-372) caches to `${RUNTIME_DIR}/.claude_pr_cache_${repo_name}_${ACCOUNT_ID}` and `..._branch_${repo_name}_${ACCOUNT_ID}`. v0.7.0 adds a stdin-first path in `build_output()` (statusline-command.sh:481-504): `.pr.number`/`.pr.url` used when present, `get_pr_number` (with its existing cache/lock) only as fallback.

**BSD/GNU split**: `fmt_epoch`/`file_mtime` still branch on `$OSTYPE` (statusline-command.sh:23-29). `parse_iso_utc` is gone (no ISO strings left to parse).

**Test coverage — no longer zero.** `scripts/test.sh` was rewritten for v0.7.0 (436 lines, 58 cases as of 2c32e0b), covering: stdin-usage render+cache, cache-fallback when stdin absent, no-segment-when-nothing-cached, per-window rollover, old-schema-treated-as-absent, stdin-first PR with gh-not-invoked / gh-fallback-invoked, `shared_login_marker`/`profile_uuid_state`, assumed-account dimming, RUNTIME_DIR creation + ownership/symlink guard, install.sh artifact/hooks-key absence, and full-tree dead-reference grep-verify. This retires the "zero test coverage" flag that applied to every prior claudeline-core review.

**skills/usage/** — `SKILL.md` and `CLAUDE.md` rewritten as a no-op explainer: usage arrives automatically on stdin each render, nothing to force-refresh; blank until the session's first API response.

Related: [[hardcoded-hook-path]] (moot — hook deleted), [[v060-render-refresh-cycle]] (describes the deleted subsystem, historical only), [[v070-stdin-cache-verification]]
