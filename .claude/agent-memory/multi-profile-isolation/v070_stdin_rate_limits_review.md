---
name: v070-stdin-rate-limits-review
description: v0.7.0 ship-gate re-verification — stdin-sourced usage kills the keychain leak, but the assumed-account cache-write path is a new, ungated conduit for the same invariant
metadata:
  type: project
---

Verified against branch `cf/v0.7.0-stdin-rate-limits` @ `2c32e0b` (2026-07-10), diff at `/Users/chadfurman/.claude/jobs/b0d15698/tmp/claudeline-v070.diff`. This is the successor review to [[leak_inventory]]'s original 2026-07-06 ranking — read that file's inline v0.7.0 annotations first, this doc is the detail behind them.

## What changed

CC ≥2.1.80 sends each statusline invocation its own `rate_limits.{five_hour,seven_day}` on stdin — session-authoritative, no fetch. v0.7.0 deletes the entire credential subsystem that used to fetch/refresh/capture a token to get this data: `hooks/show-usage-limits.sh` (711 lines), `scripts/capture-profile-session.sh`, the credential lock, `refresh_token_grant`, keychain fallback, the identity-probe auto-capture, and the `?`/`!` markers. Confirmed by grep: zero `security find-generic-password` calls remain anywhere in the live tree. `statusline-command.sh` now reads `$INPUT.rate_limits` directly (`statusline-command.sh:158-165`) and writes a same-shaped cache (`write_usage_cache`, `:117-129`) purely as a fallback for a render that lands before the session's first API response.

## Verdict 1 — is the original leak structurally dead?

**Mostly, with one residual conduit through the same root cause.**

The CRITICAL bug (macOS keychain is one slot, last `/login` wins, `show-usage-limits.sh`'s `get_token()` was asymmetric with `/status`) is genuinely gone — there's no fetch step left for it to attach to. Confirmed dead, not just deprioritized.

But a narrower, structurally distinct leak survives through the SAME pre-existing root cause (leak_inventory item 4, "env-detection defaults to work"), now with a new and worse consequence:

- `detect_account()` (`statusline-command.sh:50-59`) still has no session-authoritative signal — it's still a `CLAUDE_CONFIG_DIR` string-match heuristic, and still defaults `ACCOUNT_ID="work"`, `ACCOUNT_ASSUMED=1` whenever that env var is unset (desktop launches, background jobs, resumed sessions without the shell alias — per leak_inventory item 4, this is a real, previously-documented reachability class, not hypothetical).
- Crucially, `$INPUT` carries NO account/session identity field of its own (confirmed: only `.workspace`, `.context_window`, `.rate_limits`, `.pr` are read anywhere in the file — grepped every `jq -r` call site). So a render invoked with `CLAUDE_CONFIG_DIR` unset has a `rate_limits` payload that IS correct for whatever account CC actually authenticated the session as, but this script has no way to confirm that account is really "work."
- `write_usage_cache()` is called unconditionally from `get_usage_limits()` (`statusline-command.sh:175`) whenever stdin carries `rate_limits` — **no `ACCOUNT_ASSUMED` guard**. So: an assumed session whose real identity is personal writes personal's real numbers into `.claude_usage_limits_work.json` (`USAGE_CACHE` is keyed purely off the guessed `ACCOUNT_ID`, `:115`).
- The read-side fallback (`:184-194`) only checks that `fetched_at` is present, never that it's recent — **no TTL/staleness check on the cache-fallback read**. So a genuine work session that hits the fallback path (any render before its own fresh `rate_limits` shows up) will render the mis-attributed personal numbers, undimmed, fully attributed to `[W]`, until the work session's own next fresh stdin `rate_limits` overwrites the file. That window is not bounded to "before first API response" as the docs/changelog claim — it's bounded by "until the correctly-labeled account's own next successful write," which in a slow-moving session could be many renders.

**Reachable:** yes, via the same trigger already named in leak_inventory item 4 (desktop launch / bg job / resumed session without the alias) — no new trigger needed, just the existing one now feeding a write path that didn't previously exist in this form.

**Worse or better than before?** Better on *frequency* (old bug: guaranteed collision on every render once both profiles had ever logged in; new bug: requires the specific assumed-write race to fire at all) but arguably comparable or worse on *silence*: the old bug at least had `?`/`!` markers correlated with credential-source uncertainty (see Verdict 4). The new bug has zero marker coverage — nothing distinguishes a `[W]` render showing real work numbers from a `[W]` render showing mis-attributed personal numbers. Net: real severity drop (CRITICAL → MEDIUM-HIGH), not a full close.

**Fix, concrete and cheap:** there is no available accountUuid-on-stdin path to key off instead (checked — doesn't exist), and keying by `.claude.json`'s `accountUuid` doesn't help either, since `_CREDS_DIR`-equivalent resolution would use the SAME wrong heuristic in exactly this scenario (an assumed session resolves to `$HOME/.claude`'s `.claude.json`, i.e. work's, not the session's real one). The only defensible fix is: **never write under a guessed identity.** Add the guard the deleted `refresh_token_grant()` already had (`if [[ "$ACCOUNT_ASSUMED" == "1" ]]; then REFRESH_FAIL_REASON="account_assumed"; return 1; fi` — this exact pattern existed in the deleted hook and was NOT carried forward into `write_usage_cache`). Concretely: skip the `write_usage_cache` call at `statusline-command.sh:175` when `((ACCOUNT_ASSUMED))`. Cost: an assumed session's own future renders lose their cache-fallback (acceptable — that data's own labeling is unreliable anyway). Benefit: an assumed session can never contaminate a real account's named cache file. One-line change, direct precedent in the deleted code, currently untested (`scripts/test.sh:194-198` tests that the label dims on assumed detection, but nothing exercises "assumed session with `rate_limits` on stdin writes/pollutes a cache").

## Verdict 2 — does the surviving `=` shared_login_marker still serve the invariant?

**Noise for this domain, not a safety signal — was never load-bearing for the specific leak either version had.** `shared_login_marker()`/`profile_uuid_state()` (`statusline-command.sh:432-455`) answer "are both `.claude.json` files pointed at the literal same Anthropic account" — orthogonal to whether the *cache* is correctly attributed. Pre-v0.7.0 it correlated loosely with the credential-collision risk (same account = no harm even if the keychain shared); post-v0.7.0 there's no credential sharing left for it to correlate with at all, and it says nothing about the Verdict-1 residual leak (which happens between DIFFERENT accounts, exactly where `=` is absent and gives no warning). Keep it — it's true and cheap — but don't read it as any indication that usage-cache correctness is fine. It should not be cited as evidence against the Verdict-1 finding.

## Verdict 3 — leak_inventory reclassification

Full detail moved into [[leak_inventory]] directly (each item now carries an inline v0.7.0 status line). Summary:
- Item 1 (CRITICAL keychain) — CLOSED BY CONSTRUCTION.
- Item 2 (HIGH PR cache unkeyed) — CLOSED (now keyed `_${ACCOUNT_ID}`, confirmed in code at `statusline-command.sh:333-334,348`).
- Item 3 (MEDIUM hardcoded hook path) — CLOSED BY CONSTRUCTION (hook deleted).
- Item 4 (env defaults to work) — STILL LIVE, reclassified as the top remaining item given the new write-path consequence above.
- Item 5 (install.sh single-profile) — STILL LIVE, untouched by this diff (install.sh:8 unchanged; only the hook/capture-script install lines and `hooks.SessionStart` wiring were removed).

## Verdict 4 — did the deletion remove protection for anything OTHER than credentials?

Yes, two things, neither of which are "credential plumbing" per se:

1. **The `?`/`!` diagnostic layer itself.** These markers existed to tell the user "don't trust these numbers" independent of *why* — `?` for unverified provenance, `!` for a failed refresh. That whole class of "flag when confidence is low" signaling is gone, and nothing replaced it for the new failure mode identified in Verdict 1. This is a real regression in user-facing safety, not just simplified plumbing: previously, ANY cross-profile attribution uncertainty got flagged; now, none does.
2. **The `ACCOUNT_ASSUMED` write-guard principle.** `refresh_token_grant()` (deleted) explicitly refused to write credentials under a guessed identity. That's a general principle — never mutate named per-account state without confirmed identity — not something specific to OAuth tokens. It wasn't re-derived for the new `write_usage_cache` path. This is the direct mechanism behind Verdict 1.

Lower-severity, worth noting: the deleted `_rotate_creds_file` used tmp-file + `chmod` + atomic `mv` specifically to avoid a torn read under concurrent writers. `write_usage_cache` (`:117-129`) does a direct `jq -n ... > "$USAGE_CACHE"` — no tmp+mv. Two simultaneous renders of the same account (e.g. two terminal panes) could race a torn/truncated cache write; a reader hitting mid-write would get a jq-parse failure, which the read path already treats as absent (harmless — no fabricated data — but not the deliberate atomicity guarantee the deleted code had). LOW severity, flagging for completeness.

## Verdict 5 — ship-ready?

**Yes, conditionally.** The CRITICAL bug this whole domain exists to defend against is genuinely closed by construction — not defended, not mitigated, actually gone (no fetch step, no keychain read, nothing to race). The HIGH PR-cache leak is closed. The MEDIUM hardcoded-path item is moot by deletion.

**One condition before/immediately after ship:** add the `ACCOUNT_ASSUMED` guard to `write_usage_cache`'s call site (`statusline-command.sh:175`). This is a one-line change with direct precedent already validated in the deleted code (`refresh_token_grant`'s identical guard), currently untested, and it's the only mechanism left that can make a `[W]`-labeled render silently show a different account's real usage numbers. Given this expert's sole mandate is exactly that invariant, I'd block a "fully closed" verdict on this one line landing — but the CRITICAL/HIGH items being genuinely gone means this doesn't block ship of v0.7.0 itself, just needs to not be the last word.

Diff-test recipe from [[diff-test-recipe]] is now STALE (it invoked the deleted hook directly) — replacement recipe to construct and verify the residual leak:
```bash
# 1. Simulate an assumed-identity render carrying REAL rate_limits (as if
#    CC authenticated this session as some account, but CLAUDE_CONFIG_DIR
#    didn't propagate to this invocation):
echo '{"workspace":{"current_dir":"."},"context_window":{"used_percentage":5},"rate_limits":{"five_hour":{"used_percentage":77,"resets_at":9999999999},"seven_day":{"used_percentage":88,"resets_at":9999999999}}}' \
  | env -u CLAUDE_CONFIG_DIR bash statusline-command.sh
cat /tmp/claudeline-$(id -u)/.claude_usage_limits_work.json   # now shows 77%/88%

# 2. Simulate a REAL work render with no fresh rate_limits yet (pre-first-response):
echo '{"workspace":{"current_dir":"."},"context_window":{"used_percentage":5}}' \
  | CLAUDE_CONFIG_DIR=$HOME/.claude bash statusline-command.sh
# renders 77%/88% under [W], undimmed, indistinguishable from real work data
```
**Run against the live repo during this review, 2026-07-10, HEAD 2c32e0b.** Step 1 (assumed-identity render, `env -u CLAUDE_CONFIG_DIR`) wrote `five_hour: 77, seven_day: 88` into `.claude_usage_limits_work.json`. Step 2 (genuine work render, `CLAUDE_CONFIG_DIR=$HOME/.claude` explicitly set, undimmed `[W]` confirming `ACCOUNT_ASSUMED=0`) rendered `12pm:77% 11/20:88%` — the mis-attributed numbers from step 1, indistinguishable from real work data. Reproduced end-to-end, not just inferred from line-reading. Test artifact cleaned up after (`rm -f .../.claude_usage_limits_work.json`) to avoid leaving a poisoned cache in the user's real runtime dir.
