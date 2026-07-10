---
name: v070-fixpass-regate
description: Blocking re-gate of v0.7.0 fix-pass (ad4f8c0+a9ab2d0) — usage-cache assumed-write guard confirmed live-fixed; a structurally identical, unguarded gap found in get_pr_number's cache write
metadata:
  type: project
---

Verified against branch `cf/v0.7.0-stdin-rate-limits` @ `a9ab2d0` (2026-07-10), fix-pass delta at `/Users/chadfurman/.claude/jobs/b0d15698/tmp/claudeline-v070-fixpass.diff`, 113/113 `scripts/test.sh` passing (confirmed by direct run, not just trusted from the report). Successor to [[v070_stdin_rate_limits_review]] — read that first for the original repro and root-cause writeup.

## Verdict 1 — is the Verdict-1 usage-cache leak from the prior review actually closed?

**Yes, confirmed by live re-run of the exact prior repro, not just by reading the diff.**

`write_usage_cache()` (`statusline-command.sh:130-137`) now opens with `((ACCOUNT_ASSUMED)) && return`, directly above the docstring citing the deleted `refresh_token_grant`'s identical guard as precedent. Re-ran the two-step repro from [[v070_stdin_rate_limits_review]]:

```bash
rm -f /tmp/claudeline-$(id -u)/.claude_usage_limits_work.json
echo '{"workspace":{"current_dir":"."},"context_window":{"used_percentage":5},"rate_limits":{"five_hour":{"used_percentage":77,"resets_at":9999999999},"seven_day":{"used_percentage":88,"resets_at":9999999999}}}' \
  | env -u CLAUDE_CONFIG_DIR bash statusline-command.sh
# renders dimmed [W] 77%/88% (from stdin, unaffected) — but:
ls /tmp/claudeline-$(id -u)/.claude_usage_limits_work.json   # No such file or directory — write refused

echo '{"workspace":{"current_dir":"."},"context_window":{"used_percentage":5}}' \
  | CLAUDE_CONFIG_DIR=$HOME/.claude bash statusline-command.sh
# renders undimmed [W] with usage segment BLANK (no cache to fall back to) — no
# mis-attributed numbers, blank instead of wrong. Correct failure mode.
```

Step 1's cache file is genuinely never created (`ls`: no such file). Step 2's real work render shows no usage segment at all rather than the poisoned 77%/88% from the prior review's repro. **The exact CVE-shaped bug this gate exists to catch is closed, not just argued closed.**

Read-side 900s staleness bound also confirmed present (`:346-348`, `cache_fresh=0` when `now - cache_fetched_at > 900`) and covered by `scripts/test.sh` (`test_stale_cache_beyond_max_age_no_usage_segment`, `test_fresh_cache_within_max_age_renders`) — both pass.

## Verdict 2 — NEW finding: get_pr_number's cache write has the SAME hole, unfixed

**MEDIUM-HIGH — reachable, live-reproduced, not covered by the fix pass.** `get_pr_number()` (`statusline-command.sh:419-460`) gates its cache write only on `RUNTIME_DIR_SAFE` (`:422`) — there is **no `((ACCOUNT_ASSUMED))` guard anywhere in this function**, unlike its sibling `write_usage_cache`. The cache/branch/lock files ARE correctly `ACCOUNT_ID`-keyed (leak_inventory item 2's original CLOSED verdict on keying still holds — `:423-425`, `_${ACCOUNT_ID}` suffix confirmed present), but keying-correctly and refusing-to-write-under-a-guess are two different guarantees, and only the first one was ported over from `write_usage_cache`'s design.

Live repro, same shape as Verdict 1's:
```bash
rm -f /tmp/claudeline-$(id -u)/.claude_pr_cache_claudeline_work /tmp/claudeline-$(id -u)/.claude_pr_branch_claudeline_work
echo '{"workspace":{"current_dir":"."},"context_window":{"used_percentage":5}}' \
  | env -u CLAUDE_CONFIG_DIR bash statusline-command.sh
ls /tmp/claudeline-$(id -u)/.claude_pr_cache_claudeline_work   # EXISTS — written under ACCOUNT_ASSUMED=1
```
Confirmed: both `.claude_pr_cache_claudeline_work` and `.claude_pr_branch_claudeline_work` get created by an env-less/assumed render (`ACCOUNT_ID` guessed "work") whenever stdin lacks `.pr` and the cwd is a git repo — the exact same trigger class as leak_inventory item 4 (desktop launch, bg job, resumed session missing the shell alias).

**Why this is lower severity than the usage-cache bug, not equal:** the PR number itself comes from `gh pr view`, which is scoped by the `gh` CLI's OWN auth state in that shell — not by `CLAUDE_CONFIG_DIR` — so the data being written isn't guaranteed to even BE "the other account's" data; it's whatever `gh` resolves in that terminal, attributed to a guessed `ACCOUNT_ID`. Still a genuine violation of the domain's invariant (account-keyed state written under an unconfirmed identity), and the failure mode is identical in kind: a later, correctly-detected work session reading `.claude_pr_cache_claudeline_work` gets a PR number that was never confirmed to be work's own view of that PR.

**Fix:** same one-line pattern, same location relative to the existing guard — add `((ACCOUNT_ASSUMED)) && return` immediately after `statusline-command.sh:422`'s `[[ "$RUNTIME_DIR_SAFE" != "1" ]] && return`. Direct precedent now lives in this SAME file (`write_usage_cache`), not just in deleted code — cheaper to justify than the original fix was.

This gap predates the fix pass under review (it was already present at `2c32e0b`, part of the original v0.7.0 stdin-rate-limits diff, not introduced by `ad4f8c0`/`a9ab2d0`) — the prior review's Verdict 3 marked leak_inventory item 2 fully CLOSED on the strength of the keying fix alone and didn't check the write-guard side. That was an incomplete verdict; correcting it here.

## Verdict 3 — other angles from the gate's blocking question

1. **Any other write path with the same hole?** Checked every `((ACCOUNT_ASSUMED))` reference (`grep -n`) and every write site under `RUNTIME_DIR`: only `write_usage_cache` (guarded) and `get_pr_number`'s cache/branch/lock writes (unguarded, Verdict 2). No third writer exists.
2. **Can a pre-existing (pre-fix) poisoned usage cache still render post-upgrade?** Yes, but self-healing and bounded: any cache file older than 900s at next read is dropped regardless of how it got there (age-gated, not provenance-gated). A cache written by the OLD buggy binary less than 900s before the user upgrades could render once or twice more before aging out — a ≤15-minute residual window, not indefinite. Not separately blocking; flagging as informational only. Could not verify against the user's actual `/tmp` state (this session's `/tmp/claudeline-501/` is this sandbox's own, not necessarily representative) — if this matters operationally, check the real cache file's `fetched_at` age directly rather than assuming.
3. **Can a legit session's periodic refresh perpetually launder a poisoned value?** No — analyzed the refresh-floor logic: `write_usage_cache` only skips (leaves `fetched_at` frozen) when written values EXACTLY match what's on disk; any mismatch (which a genuine account's real numbers vs. a poisoned cross-account value would produce, barring exact-coincidence collision) triggers an overwrite with real data. No path found where a legitimate session's own repeated writes refresh `fetched_at` on data it didn't itself provide.
4. **UX cost of the `ACCOUNT_ASSUMED` write refusal.** Real but narrow: a legitimately env-less work session (missing the shell alias) now never gets a cache-fallback for ITS OWN early renders (before its first API response arrives on stdin) — previously such a session could seed its own fallback cache across invocations; now every one of its pre-first-response renders shows a blank usage segment instead. Bounded to "before first API response," which the existing docs already frame as the expected blank-bar window — this just makes that window slightly more likely to be hit for this one session class. Correct trade: silently rendering a POSSIBLY wrong account's real numbers is strictly worse than a blank segment for a few extra renders. Not a UX regression worth blocking on.
5. **New risk from the 900s/300s bounds, atomic tmp+mv, or `strip_ctrl`?** None found — all three are same-account-scoped mechanics (staleness bound and refresh floor operate only after `ACCOUNT_ID`/`ACCOUNT_ASSUMED` are already resolved for the file being touched; `strip_ctrl` operates on git-derived branch/repo strings, orthogonal to account isolation). Tmp-file name uses `$$` (PID) not account — theoretically two processes racing on the SAME account's cache could collide on PID reuse, but that's a same-account robustness question, out of this domain's scope, and not new (no prior tmp+mv existed to compare against).

## Verdict 4 — leak_inventory reclassification

Item 2 status is **PARTIALLY REOPENED**: keying is correct (`_${ACCOUNT_ID}` suffix, confirmed) but the write-under-guessed-identity guard is absent from `get_pr_number`, unlike its sibling `write_usage_cache`. Update inline status in [[leak_inventory]] accordingly.

## Verdict 5 — ship-ready?

**Yes, conditionally — same shape as the prior gate's answer.** The CRITICAL keychain bug and the specific residual leak this gate was called to re-verify (usage-cache assumed-write) are both genuinely closed, live-reproduced against the actual current HEAD, not inferred from the diff or trusted from the report. 113/113 tests pass, confirmed by direct run.

**One new condition, same cost class as the last one:** add `((ACCOUNT_ASSUMED)) && return` to `get_pr_number()` right after its existing `RUNTIME_DIR_SAFE` check (`statusline-command.sh:422`). One line, direct precedent now in-file, currently untested (no `scripts/test.sh` coverage exercises an assumed session hitting the PR-cache write path — the C1 test block covers usage-cache only). Lower severity than the condition on the prior gate (PR numbers aren't usage/quota data, and the source of truth is `gh`'s own auth, not the Claude account), so I would NOT block ship of this fix-pass on it alone, but it should not be the last word either — same posture as Verdict 5 in [[v070_stdin_rate_limits_review]].
