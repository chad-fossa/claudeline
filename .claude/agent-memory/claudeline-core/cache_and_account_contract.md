---
name: cache-and-account-contract
description: Usage-cache schema, account-detection rule, and TTL/lock mechanics shared by statusline-command.sh and hooks/show-usage-limits.sh
metadata:
  type: reference
---

Confirmed against code 2026-07-06.

**Cache file**: `/tmp/.claude_usage_limits_${ACCOUNT_ID}.json`, written by `hooks/show-usage-limits.sh` (`CACHE_FILE`, line 14) and read by `statusline-command.sh` `get_usage_limits()` (line 74/100-143). Schema: `.five_hour.utilization`, `.five_hour.resets_at`, `.seven_day.utilization`, `.seven_day.resets_at`, plus `.fetched_at` (epoch seconds, added by the hook at write time via `jq --arg ts "$(date +%s)"`, hooks/show-usage-limits.sh:120-122). Values already percentages (15.0 = 15%), not fractions.

**TTL**: 300s (`USAGE_CACHE_TTL_SECONDS`, statusline-command.sh:75). `maybe_refresh_usage_cache()` (lines 82-98) compares `now - file_mtime($CACHE)` against the TTL — it does NOT read `fetched_at` from the JSON for staleness, it uses the file's mtime. A 30s lock file (`/tmp/.claude_usage_refresh_lock_${ACCOUNT_ID}`) prevents stampede; render always shows whatever's on disk now, refreshed data appears next render.

**Account detection rule** (duplicated verbatim-logic in two places — must update both):
- statusline-command.sh:50-58
- hooks/show-usage-limits.sh:7-13

Rule: `CLAUDE_CONFIG_DIR` substring-matches `"claude-personal"` → `ACCOUNT_ID="personal"`; anything else, including unset, → `ACCOUNT_ID="work"`. This is a default-to-work trap: any config dir that isn't literally named with `claude-personal` in it silently becomes "work", no error surfaced. Chosen deliberately over `transcript_path` because transcript_path follows symlinks and personal→work symlinked projects resolve to `/.claude/` (d9613aa commit message).

**get_token() churn** (hooks/show-usage-limits.sh:33-51) — 3 rewrites, extra scrutiny warranted on any future touch:
1. `89b0c6b` (initial) — simple keychain lookup, single account, no isolation concept yet.
2. `d9613aa` (2026-03-13) — added multi-account support + a hashed-keychain-entry (`Claude Code-credentials-{hash}`) fallback intended to isolate personal from work. Broken: hashed entries only hold empty-`accessToken` MCP OAuth tokens, and an unanchored grep matched them anyway, silently returning empty/wrong tokens.
3. `e9295da` (2026-05-10) — reverted the hashed-entry fallback. **~2-month window (2026-03-13 to 2026-05-10) where personal-account usage stats silently failed**, only symptom being a stderr line ("Usage: Could not get credentials" or bad data), no hard error. Forward-fix: always read the single default `Claude Code-credentials` entry, anchor the grep on `"claudeAiOauth":{"accessToken":"..."}`. The macOS keychain single-slot limitation itself (upstream anthropics/claude-code#20553 — last `/login` wins across all profiles) is now documented as a known constraint, not worked around.
4. `d0c8df7` — added Linux branch: reads `$CLAUDE_CONFIG_DIR/.credentials.json` via `jq` (properly isolated per config dir — Linux has cleaner multi-profile behavior than macOS here). Uses `jq`, not grep, since the file isn't keychain-truncated.

Grep-not-jq on macOS is deliberate: keychain entries with MCP-token bloat can get truncated at keychain's read limit and break JSON parsing; grep degrades gracefully.

**PR cache is unkeyed by account** — `get_pr_number()` (statusline-command.sh:247-288) caches to `/tmp/.claude_pr_cache_${repo_name}` and `/tmp/.claude_pr_branch_${repo_name}`, keyed only by repo name. Two profiles working the same repo share one PR cache — confirmed still true in current code, standing HIGH-severity leak, not this expert's call to fix without multi-profile-isolation's diagnosis per the cluster split, though the fix (rekey by `${repo_name}_${ACCOUNT_ID}`) lands in this expert's file when authorized. Note: the domain-bootstrap research claims the user's separate dotfiles copy of statusline-command.sh already has this fix (account-keyed PR cache) — this repo's copy does not; treat dotfiles-vs-repo drift as real until reconciled.

**BSD/GNU split**: both files branch on `$OSTYPE` for `parse_iso_utc`/`fmt_epoch` (`statusline-command.sh:23-31`, `hooks/show-usage-limits.sh:24-30`); only statusline-command.sh also has `file_mtime` (line 26/30) since only it needs stat. Any new date/stat call must go through these helpers.

**Zero test coverage** on this entire surface (statusline-command.sh, hooks/, skills/usage/) — confirmed, no test files found. A framework-level fix is out of scope unless asked; flag any change that could have shipped a regression a test would've caught (e.g. the 2-month get_token() silent failure above — a single test asserting the grep pattern matches a real keychain payload shape would have caught it before merge).

**skills/usage/** — `SKILL.md` documents `/usage` as a manual re-invocation of `hooks/show-usage-limits.sh` with `'{}'` piped to stdin, sharing the same per-account cache contract as the background refresh path. Not yet deep-read line-by-line; treat as thin wrapper around the same hook until a diff touches it.

Related: [[hardcoded-hook-path]]
