---
name: v070-stdin-cache-verification
description: v0.7.0 ship-gate verification — stdin-sourced usage replaces the OAuth-fetch subsystem entirely; all 7 design decisions HONORED, 58/58 tests pass
metadata:
  type: reference
---

Verified 2026-07-10, branch `cf/v0.7.0-stdin-rate-limits` @ `2c32e0b`, against spec `claudeline-v070-spec.md` and diff `claudeline-v070.diff`.

**Result: SHIP-READY.** All 7 binding design decisions HONORED, no dangling references to the deleted credential subsystem in any shipped file, `bash scripts/test.sh` → `PASS: 58 FAIL: 0`.

## Per-decision verdicts

1. Cache redesign — HONORED. `write_usage_cache()` (statusline-command.sh:117-129) writes the stdin-mirror schema (`five_hour.{used_percentage,resets_at}`, `seven_day.{...}`, `fetched_at`) inline, synchronously, no lock/background spawn.
2. Per-window rollover staleness — HONORED. statusline-command.sh:204-215 checks `now > resets_at` independently per window. `USAGE_CACHE_TTL_SECONDS`/`maybe_refresh_usage_cache` confirmed absent (grep, full tree). Anti-fabrication guard (`fetched_at` empty check, line 194) survives and correctly treats an old v0.6.x-shaped cache as absent.
3. Markers — HONORED. `unverifiable_marker` and its call sites fully deleted (grep-clean). `shared_login_marker`/`profile_uuid_state` kept verbatim (statusline-command.sh:432-455) and still functional (test-verified).
4. Fetch/refresh/capture subsystem deletion — HONORED. `hooks/` directory itself is gone (not just the file inside it); `scripts/capture-profile-session.sh` gone; `maybe_refresh_usage_cache`, `resolve_usage_refresh_hook`/`USAGE_REFRESH_HOOK`, `parse_iso_utc`, `token_source`/`provenance` all absent from statusline-command.sh and install.sh (grep-verified against the full tree, not just the two named files).
5. `verify_runtime_dir`/`RUNTIME_DIR`, `get_context`, `progress_bar`, `detect_account` — HONORED, kept verbatim (statusline-command.sh:84-105, 229-244, 246-284, 50-60). `detect_account` is now explicitly the sole copy (comment at line 48-49), no cross-file sync concern.
6. PR stdin-first + gh fallback — HONORED. `build_output()` (statusline-command.sh:481-504) uses `.pr.number`/`.pr.url` when present, falls back to `get_pr_number()` (cache/lock intact, statusline-command.sh:328-372) otherwise.
7. No legacy OAuth fallback — HONORED. No `get_token`, no keychain/`security` calls, no `.credentials.json` reads anywhere in the shipped tree.

## Render+refresh-cycle findings (new-code lens)

- **(a) Cache write atomicity**: NOT atomic — `write_usage_cache()` writes directly via `jq -n ... > "$USAGE_CACHE"` (statusline-command.sh:128), no tmp+mv, no lock (deliberate per spec). A kill mid-write can leave truncated/partial JSON. Safe by construction, not by design: the next render's `jq -r` read on malformed JSON fails/emits empty output, which folds to an empty `fetched_at` and is caught by the existing anti-fabrication guard (statusline-command.sh:194) — render nothing, never garbage. Flagged as fragile-but-safe; an explicit tmp+mv would remove reliance on jq's failure mode lining up with the guard.
- **(b) Float rounding / 0% vs absent**: `awk "BEGIN {printf \"%.0f\", $pct_raw}"` (statusline-command.sh:137) correctly rounds `14.000000000000002` → `14`. A legit `0%` is distinguishable from absent: jq's `tostring` on `0` yields `"0"` (non-empty), and every presence check tests emptiness/`"null"`, not falsiness (verified lines 170, 195, 207) — `0%` renders correctly, absence renders nothing.
- **(c) One window present, other absent**: renders the present one, omits the absent one — does NOT bail entirely. `seg5`/`seg7` are computed independently (statusline-command.sh:207-215); the combined bail (`[[ -z "$combined" ]] && return`, line 221) only fires when BOTH are empty. Test-verified (`test_per_window_rollover_5h_expired_7d_valid`).
- **(d) Hook-written assumption**: none found. Only remaining "hook" reference in shipped code is a historical explanatory comment (statusline-command.sh:49, "no separate hook/capture script needing an identical copy to stay in sync") — not a live dependency.
- **(e) `bash scripts/test.sh`**: `PASS: 58 FAIL: 0`.

## Test coverage note

This is the first time this surface has had real test coverage — `scripts/test.sh` was rewritten (not trimmed) for v0.7.0, 58 cases, covering every new behavior above plus install.sh's no-hooks-key assertion. The long-standing "zero test coverage" flag on this surface (see superseded [[cache-and-account-contract]] history) no longer applies.

Related: [[cache-and-account-contract]] (current schema, rewritten same session), [[hardcoded-hook-path]] (superseded — hook deleted), [[v060-render-refresh-cycle]] (superseded — subsystem deleted), [[v070-final-regate]] (2026-07-10 re-gate — corrects finding (c) below and adds two new gaps)

## Correction (2026-07-10, [[v070-final-regate]])

Finding **(c) above was wrong as generalized.** It described independent
per-window ROLLOVER checking on already-resolved values (true, and still
true). It did NOT cover independent per-window STDIN-vs-cache gating, which
at 2c32e0b was NOT independent: `get_usage_limits()` gated the entire
stdin/cache branch on `stdin_five_pct` alone (old statusline-command.sh, the
`if [[ -n "$stdin_five_pct" ...`/`else` split). Live-reproduced at 2c32e0b: a
seven-only stdin payload (no `five_hour` key at all) rendered NOTHING and
cached NOTHING; a five-only payload rendered/cached correctly. Two other
reviewers caught this; I missed it by conflating it with (c). Fixed in
da10aac (`resolve_window()` + `resolve_usage_values()`, current
statusline-command.sh:203-264) — confirmed fixed by re-running both
single-window payloads live against current code (a9ab2d0): both render and
cache correctly now.
