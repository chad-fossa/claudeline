---
name: v070-regate2-pass2
description: v0.7.0 ship-gate pass 2 @ 9a174f8 (delta a9ab2d0..HEAD) — SHIP; FIX3/FIX2(folder) confirmed fixed live; tmp-leak still open (not multiplied per-render); jq-spawn real count 5/7/11 (not flat 70ms); NEW concurrent RMW lost-update+false-freshness race found in write_usage_window
metadata:
  type: reference
---

Re-gated 2026-07-10/11 (session date drifted mid-task), `cf/v0.7.0-stdin-rate-limits`
@ `9a174f8`, delta reviewed = `a9ab2d0..HEAD` (4 commits: f6b971e PR-cache identity
guard, 5579b3d context_window_size validation, 47b975c folder strip_ctrl, 9a174f8
per-window fetched_at). `bash scripts/test.sh` → 136/136 PASS, run directly.

**Verdict: SHIP.** Both of my prior findings that this delta targeted (file-global
fetched_at, unstripped folder) are fixed and live-verified. Two items remain open
(tmp leak, and a newly-found concurrent RMW race) but neither fabricates or
stale-renders in the way the project invariant forbids — degraded freshness by
~1 render-cycle, not a fabricated number. Track, don't block on, from this
subsystem alone.

## Prior items, final disposition

1. Contradiction (stdin gating) — resolved before a9ab2d0, not part of this delta.
2. Atomic write / tmp-leak-on-jq-failure — **OPEN, unfixed**. `write_usage_window`
   still has no `rm -f "$tmp"`/trap. Tested the "does 2x write_usage_window calls
   per render multiply the leak" question directly (stubbed jq to fail on call N):
   worst-case debris is still bounded to 1 leftover file per render, NOT 2 — both
   calls share the same `${USAGE_CACHE}.tmp.$$` name (`$$` = script's own PID,
   constant across both calls in one process), so a later successful call
   silently overwrites/clears an earlier failed call's debris. But the number of
   independent write *attempts* per render doubled, so P(any leak this render)
   roughly doubles even though per-incident debris volume didn't. Still a trivial
   2-line fix, still not done.
3. File-global `fetched_at` (9a174f8) — **FIXED, live-verified**. Seeded
   `seven_day:90%` with `fetched_at` 1200s old (>900s bound; the prompt's literal
   600s repro is actually still-fresh and correctly still renders — re-ran at
   1200s to see the blank-out), rendered 3x with only `five_hour` churning:
   `seven_day` never rendered, its `fetched_at` stayed byte-identical to seeded
   value across all 3 renders. Sibling carry-forward preserves the sibling's own
   `fetched_at` verbatim from disk — confirmed no remaining cross-window
   freshness leak.
4. strip_ctrl folder gap (47b975c) — **FIXED**. `folder=$(strip_ctrl "$(basename
   "$CWD")")` at statusline-command.sh:666. Re-audited every printf/stdout site;
   folder was the last unguarded stdin-derived string reaching output.
5. jq-spawn regression — **OPEN, real, worse than quoted, trivially fixable**.
   Measured (counting jq stub, not estimated): 5 spawns (no stdin rate_limits),
   7 (steady-state, unchanged, within 300s floor), 11 (both windows changing
   every render — the realistic active-session case). a9ab2d0 baseline: ~2
   steady / ~3-4 worst case. Wall-clock 5-run avg: steady-state HEAD ≈90ms/render
   (matches the ~70ms claim), but churning-values case ≈152ms/render vs
   a9ab2d0's ≈77ms — a genuine ~2x regression in the case that actually happens
   during active token burn, not the idle path the 70ms figure came from. Root
   cause: `write_usage_window` independently re-reads (via its own internal
   `read_cached_window` call) the same window's values `resolve_usage_values`
   already read moments earlier, and separately re-reads the sibling from disk
   even though `resolve_usage_values` already holds both windows' cached values
   in local variables. Threading those values in as parameters instead of two
   more disk reads would ~halve spawns with no design change.

## New surface found this pass: concurrent RMW race in write_usage_window

Confirmed via deterministic simulation (delayed one write between its
sibling-read and its `mv` to force interleaving): two concurrent same-account
renders, each carrying only ONE window on stdin (normal per the project's own
"each window independently absent" contract) — Session B writes
`seven_day=99` and completes; Session A (read the sibling as `seven_day=1`
BEFORE B's write landed) then completes its own `five_hour` write, carrying
forward the stale `seven_day=1` and silently clobbering B's `99`.

Worse than a plain lost update: A's write re-stamps the reverted stale
`seven_day` with A's OWN fresh `fetched_at`. The lost value doesn't just
vanish — it comes back looking freshly-verified and will pass the 900s read
bound, rendering as current. This is a race that *manufactures* a false-fresh
stale value, in real tension with [[cache_and_account_contract]]'s core
invariant. Requires two concurrent renders of the same ACCOUNT_ID (e.g. two
terminal tabs on "work") — realistic, not contrived, given asymmetric-window
stdin is the norm not the exception.

Separately tested and distinguished (do not conflate with the race above):
- Wrong-shape sibling (valid JSON, wrong type, e.g. sibling is a bare string):
  carried forward verbatim forever, no self-heal, but downstream reads on it
  fail safely (jq indexing error → renders blank, no crash, no fabrication).
- Fully-corrupt (non-JSON) cache file: self-heals — sibling read fails
  silently, defaults to null, whole file gets replaced with valid schema on
  next write.
- No-forward-migration of legacy (pre-fix, file-global-fetched_at) cache:
  confirmed SAFE as designed — reads back unfresh, blanks correctly, fully
  replaced on next stdin write. Fine given it's a /tmp throwaway.

Fix path if picked up: lock around the sibling-read-then-write, same pattern
`get_pr_number` already uses (`.claude_pr_lock_*`).

## Comments (item 6)

No fresh WHAT-narration violations introduced by this diff. New comments in
`read_cached_window`/`window_cache_fresh`/`write_usage_window`/
`resolve_usage_values` are WHY-oriented, consistent with this file's
pre-existing (already verbose-by-repo-norm) style elsewhere. `read_cached_window`'s
docstring is the most verbose addition (~5 lines for a 4-line function) but
documents a non-obvious contract (legacy cache reads back empty, on purpose —
that's the exact bug class this pass fixed) — justified, tightenable, not a
violation.

Related: [[v070_final_regate]] (pass 1, @a9ab2d0, the five items this pass
re-checked), [[cache_and_account_contract]], [[v070_stdin_cache_verification]].
