---
name: v070-final-regate
description: v0.7.0 final ship-gate re-check @ a9ab2d0 — contradiction resolved (other reviewers were right), two new gaps found (folder-name strip_ctrl miss, file-global fetched_at)
metadata:
  type: reference
---

Re-gated 2026-07-10, `cf/v0.7.0-stdin-rate-limits` @ `a9ab2d0`, against fix-pass
diff (da10aac..a9ab2d0) on top of the state verified at 2c32e0b (see
[[v070-stdin-cache-verification]]). `bash scripts/test.sh` → 113/113 PASS
(confirmed by direct run, not just trusting the reported number).

**Verdict: CONDITIONAL ship.** Block on the strip_ctrl gap (#4 below, trivial
one-line fix, same pattern already used three other places in this file).
The fetched_at-granularity gap (#3) is a real but lower-confidence-of-impact
design issue — recommend fixing before push, but it's a judgment call, not a
hard blocker, since its real-world trigger rate depends on how often
Claude Code's stdin sends the two windows asymmetrically (unverified from
inside this repo).

## 1. Contradiction — RESOLVED, other reviewers were right

See correction appended to [[v070-stdin-cache-verification]]. At 2c32e0b,
`get_usage_limits()` gated the *entire* stdin-vs-cache branch on
`stdin_five_pct` alone — a seven-only payload rendered and cached nothing.
Live-reproduced both directions at 2c32e0b (five-only worked, seven-only
didn't) and confirmed fixed at current HEAD (both directions render+cache
correctly) — see the two `resolve_window()`/`resolve_usage_values()` calls,
statusline-command.sh:203-264.

## 2. Atomic cache write — mostly fixed, one uncovered edge

`write_usage_cache()` (statusline-command.sh:129-177): `tmp="${USAGE_CACHE}.tmp.$$"`
(line 167) — inside the 0700 `RUNTIME_DIR` (same dir as `$USAGE_CACHE`, so
`mv -f` at line 176 is a same-filesystem `rename()`, genuinely atomic), and
uniquely named per invocation via `$$` (own PID; each statusline invocation
is a fresh process, so no two concurrent renders for the same account can
collide). Live-tested: no tearing possible — a reader only ever sees the
old file, or a fully-formed new one, never a partial write.

**Gap**: no cleanup on jq failure. `jq -n ... > "$tmp" 2>/dev/null && mv -f "$tmp" "$USAGE_CACHE"`
— if `jq` fails, `$tmp` is left on disk (confirmed live: stubbed `jq` to
fail, `.claude_usage_limits_work.json.tmp.<pid>` remained in `RUNTIME_DIR`
afterward). No `rm -f "$tmp"` fallback, no trap. Not a tearing/correctness
risk (the real cache file is never touched on failure), just an
accumulating-file leak on repeated jq failures. Not covered by
`scripts/test.sh` (its atomic-write test only checks the success path,
line ~839 `wuc_tmp_leftover`). Low severity, worth a follow-up one-liner
(`|| rm -f "$tmp"`), not a blocker.

## 3. 300s write-floor / 900s read-bound interaction — real gap, file-global fetched_at

Confirmed correct for the tested/designed case: a render where stdin
resupplies the SAME values as a >=300s-stale cache still forces a rewrite
(refreshing `fetched_at`), so a genuinely-flat usage window never ages past
the 900s read bound as long as renders keep happening. Verified via the
shipped e2e test and independently by hand.

**New gap live-reproduced**: `fetched_at` is a single timestamp for the
whole cache record (both windows), not per-window
(statusline-command.sh:238-247 read, :150-176 write). If one window's stdin
value keeps changing every render (forcing `write_usage_cache` to fire and
refresh `fetched_at` to "now" each time) while the OTHER window's cached
value is genuinely old (its own last real update was, say, 10+ minutes
ago), the sibling's churn keeps propping up `fetched_at` and the stale
window's cache read never trips the 900s bound — it renders indefinitely as
if current. Live-reproduced: seeded `seven_day: 90%` with `fetched_at` 600s
old, then rendered three times with only `five_hour` changing each time
(`11%`, `12%`, `13%`) — `seven_day: 90%` rendered every time, undimmed, and
`fetched_at` kept advancing to "now" on each render even though `seven_day`
itself was never re-verified. This is exactly the "stale numbers rendering
as current" class this project's whole design explicitly guards against
(anti-fabrication guard, per-window rollover). The C2 fix (da10aac) made
window *selection* (stdin-vs-cache) independent per window but didn't make
the *freshness bound* independent per window — worth a follow-up (split
`fetched_at` into `five_hour.fetched_at`/`seven_day.fetched_at`, or track
per-window last-stdin-seen time). Real-world frequency depends on how often
Claude Code's stdin sends the two windows asymmetrically — not something
this repo can determine on its own.

## 4. strip_ctrl coverage — UTF-8-safe, but one render path unguarded (live-exploitable)

`strip_ctrl()` (statusline-command.sh:401-403, `tr -d '\000-\037\177'`) is
correctly UTF-8-safe: octal-escape byte ranges in `tr -d` operate byte-wise
regardless of locale, so multi-byte UTF-8 sequences (>=0x80) pass through
untouched while C0/DEL are stripped. Verified live with a branch name
containing `é` (`\xc3\xa9`) and `🚀` (`\xf0\x9f\x9a\x80`) plus an embedded
ESC — both multi-byte chars survived byte-for-byte, only the ESC was
removed.

Applied at: `get_repo_name` (:372), `get_branch` (:416), both `hyperlink()`
args (:408-409, covering every `pr_link_for`/URL/text caller), and
`resolve_pr`'s `stdin_pr_number` (:489).

**Not applied**: the non-git-repo render path's `folder` variable
(`folder=$(basename "$CWD")`, statusline-command.sh:632-633, rendered raw at
:639). `$CWD` comes straight from stdin's `.workspace.current_dir` (:35),
unsanitized. Live-reproduced: created a directory literally named
`evil<ESC>]52;c;PWNED`, pointed `workspace.current_dir` at it, and the
rendered statusline output contained the raw ESC byte followed by the OSC 52
clipboard-write sequence, unstripped — the exact attack strip_ctrl's own
comment (:397-400) names as the reason it exists. This is a live,
currently-shippable gap in the same vulnerability class the D2 batch
(eed3b70) was written to close, just missing one call site. One-line fix:
`folder=$(strip_ctrl "$(basename "$CWD")")`. **Recommend blocking push on
this** — it's the same severity class as what D2 already fixed elsewhere,
trivial to fix, and not covered by any existing test.

## 5. resolve_pr / jq folds — no functional regression, but a real jq-spawn-count regression

`resolve_pr()` (statusline-command.sh:481-505) extraction is functionally
correct — no render-path regression found. PR field reads went from 2 jq
spawns (separate `.pr.number`/`.pr.url` calls in old `build_output`) to 1
folded call (:487) — net **-1** spawn, matches the shipped test
(`test_pr_fields_folded_into_one_jq_call`).

**Usage-side spawn count went up**, not flagged anywhere in the fix-pass
commits or tests. `resolve_usage_values()` (:217-264) now *always* attempts
a cache read (:241, gated only on `[[ -f "$USAGE_CACHE" ]]`) even when
stdin already fully supplies both windows and the cache read's result will
never be used — at 2c32e0b, the old `get_usage_limits()` only read the
cache in the `else` branch (i.e., only when stdin didn't supply
`five_hour`), so a full-stdin render skipped that jq spawn entirely.
`write_usage_cache()` adds a further comparison-read jq call (:153) every
time it's invoked. Net, once a cache file exists (true for almost every
real render past the first): old hot path (both windows in stdin) = 2 jq
spawns for usage (stdin-parse + write). New hot path = 3-4 (stdin-parse +
cache-read + write-compare-read + maybe write) depending on whether the
300s floor trips. This is a real, unflagged perf regression (~2x jq spawns
for usage handling in the common case) — jq subprocess spawn is typically
the dominant per-render cost in this kind of bash script. Not a correctness
issue, and the tradeoff (fewer disk writes via the skip-if-unchanged
optimization) may be worth it, but it should have been called out in the
fix-pass writeup and wasn't.

## 6. Test run

`bash scripts/test.sh` → `PASS: 113 FAIL: 0`, run directly, not taken on
faith from the prompt's claimed number.

Related: [[v070-stdin-cache-verification]], [[cache-and-account-contract]]
