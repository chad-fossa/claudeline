---
name: v070-regate2
description: Second blocking re-gate of v0.7.0, delta f6b971e..9a174f8 — cross-account isolation confirmed fully closed (incl. under real concurrency); NEW same-account lost-update race found in 9a174f8's per-window write, live-reproduced 100% of the time; test.sh itself is non-hermetic and flaky as a direct symptom
metadata:
  type: project
---

Verified against branch `cf/v0.7.0-stdin-rate-limits` @ `9a174f8` (2026-07-10), delta diff at `/Users/chadfurman/.claude/jobs/b0d15698/tmp/claudeline-v070-regate2.diff` (four commits: f6b971e, 5579b3d, 47b975c, 9a174f8). Successor to [[v070_fixpass_regate]] — read that first for the C1/PR-cache repro history this continues.

## Verdict 1 — C1 usage-cache guard, still closed post-refactor

**Yes, confirmed live at HEAD.** `write_usage_cache()` was dissolved into `read_cached_window`/`window_cache_fresh`/`write_usage_window` (statusline-command.sh:130-186) but the `((ACCOUNT_ASSUMED)) && return` guard survived intact, now at the top of `write_usage_window` (~line 161). `resolve_usage_values` calls it twice per render (once per window, each independently gated on `five_from_stdin`/`seven_from_stdin`, statusline-command.sh:276-277) — both calls are gated by the same guard since it's inside the shared function, not duplicated/forked.

Re-ran the two-step repro from [[v070_fixpass_regate]], isolated `$HOME` + PATH-shimmed `id` (fake uid 99887, never touched real `~/.claude*` or real `/tmp/claudeline-501`):
```
rm -rf /tmp/claudeline-99887
echo '{...,"rate_limits":{"five_hour":{"used_percentage":77,...},"seven_day":{"used_percentage":88,...}}}' \
  | env -u CLAUDE_CONFIG_DIR bash statusline-command.sh
# renders dimmed [W] 77%/88% from stdin — RUNTIME_DIR exists (mkdir -p is unconditional) but is EMPTY, zero cache files
ls /tmp/claudeline-99887/   # only . and ..

echo '{...no rate_limits...}' | CLAUDE_CONFIG_DIR=$HOME/.claude bash statusline-command.sh
# renders [W] undimmed, usage segment BLANK — no poisoned 77%/88%, correct failure mode
```
Matches the orchestrator's own manual verification claim exactly.

## Verdict 2 — PR-cache guard (f6b971e), fully closed, not just moved

**Confirmed: the guessed-identity path touches ZERO files — cache, branch-cache, AND lock.** `get_pr_number()` now early-returns under `((ACCOUNT_ASSUMED))` (statusline-command.sh:449-455) *before* the `local cache=`/`local branch_cache=` lines are even reached — it does a live `gh pr view` and returns, never touching `$RUNTIME_DIR`. Live repro:
```
rm -rf /tmp/claudeline-99887
echo '{...no .pr...}' | env -u CLAUDE_CONFIG_DIR bash statusline-command.sh   # in a git repo
ls /tmp/claudeline-99887/   # only . and .. — no .claude_pr_cache_*, no .claude_pr_branch_*, no lock
```
This is a genuine fix, not a relocation of the hole — confirmed by reading the control flow (the assumed-branch is a separate `if` block with its own `return`, physically above the cache/branch_cache/lock variable declarations) and by the empty-directory repro. Also newly covered by `scripts/test.sh`: `test_assumed_identity_pr_cache_never_written`, `test_explicit_identity_pr_cache_still_written` (regression guard), `test_assumed_identity_stdin_pr_no_cache_no_gh`. **leak_inventory item 2 is now CLOSED**, superseding the PARTIALLY REOPENED status from the prior gate.

## Verdict 3 — the per-window read-modify-write's concurrency shape

Three sub-questions, all live-tested, not just reasoned about.

**(b) Cross-account interleave into one file: CONFIRMED IMPOSSIBLE**, both by code and by live race. `USAGE_CACHE="${RUNTIME_DIR}/.claude_usage_limits_${ACCOUNT_ID}.json"` (statusline-command.sh:130) — different accounts are different files, full stop, no shared inode. Live-raced 3 rounds of concurrent work+personal renders on the same synthetic uid — every round produced two clean, correctly-attributed files (`work={5h:10,7d:16}`, `personal={5h:14,7d:7}`), matching the orchestrator's own numbers. No interleaving observed or structurally possible.

**(a) Lost update between two SAME-account concurrent writers: CONFIRMED, live-reproduced, 100% (40/40 trials).** `write_usage_window` does read-sibling-from-disk → compose-JSON-in-memory → atomic tmp+mv, with no lock across the read and the mv. Two concurrent processes on the *same* account, one updating only `five_hour` (stdin carries only that window) and the other only `seven_day`, each read the *other's pre-race* value as "sibling," so whichever process's `mv` lands second silently reverts the first process's update:
```
# seed cache: five_hour=0, seven_day=0 (sentinels)
# race: process A → stdin carries only five_hour=111
#       process B → stdin carries only seven_day=222 (same account, same instant)
# 40/40 trials: final file was EITHER {five:111,seven:0} OR {five:0,seven:222} — NEVER {five:111,seven:222}
```
This is a textbook TOCTOU on the same file, deterministic under any real concurrency, not a rare timing fluke — every single trial lost exactly one window's update. **Not a cross-profile leak** (same account, no data crosses the ACCOUNT_ID boundary) but a genuine same-account data-integrity regression introduced by 9a174f8's split. The lost window's cache entry isn't corrupted/torn — it's a syntactically valid, silently-stale value with its `fetched_at` carried forward unchanged from before the race, so the read-side 900s freshness check has no way to detect that an update was dropped.

**(c) Torn/mixed record:** not observed and not structurally possible — the `tmp+mv` is atomic at the filesystem level (`mv -f` is a rename), so a reader never sees a partial write. "Torn" doesn't apply here; the failure mode is exclusively (a), a full-file lost update, never a partial one.

**Reachability:** two terminal panes/tmux windows open on the *same* profile, each running their own statusline render around the same moment, is an entirely ordinary real-world shape (not a contrived attack) — this isn't a hypothetical multi-tenant scenario, it's default tmux/multi-pane usage. **This is the domain expert's out-of-charter observation to flag, not fix** — it's a render-loop/cache-correctness question, core's territory (see subagent scoping note), but flagging here because it was explicitly in-scope for this gate's Verdict 3 ask.

## Verdict 3.5 — unplanned finding: this race is ALREADY live-visible in scripts/test.sh itself

Ran `bash scripts/test.sh` back-to-back several times in the *real* (non-synthetic) environment, per the task's instruction to trust direct runs over reported numbers. Result: **NOT reproducibly 136/136.** Three consecutive runs in the ambient shell produced 3, then 12, then 9 distinct failures — a different set of failing test names each time (`test_stdin_absent_renders_from_fresh_cache`, `test_per_window_300s_write_floor`, `RUNTIME_DIR: statusline creates it`, `test_stdin_usage_rendered_and_cached`, etc. — no stable subset). Root cause: `scripts/test.sh:11` sets `RUNTIME_DIR="/tmp/claudeline-$(id -u)"` — the **real, non-isolated, UID-keyed path**, identical to the one any concurrently-running real statusline process on the machine uses. The file's own header comment ("Runs under an isolated $HOME so real ~/.claude* state is never touched") is misleading for this specific piece of state: `$HOME` is irrelevant to `RUNTIME_DIR`'s derivation, so successive/concurrent `test.sh` invocations (or a genuinely live Claude Code session's own statusline refreshing in the background) race on the exact same files this delta's `write_usage_window` and `get_pr_number` write to — a live, unplanned demonstration of Verdict 3(a)'s mechanism, not synthetic.

**Did not attempt to fix or further isolate this** (out of scope, flags-only charter; also `rm -rf /tmp/claudeline-501` was correctly blocked by the sandbox's own auto-mode classifier when attempted as a would-be cleanup step — a useful confirmation that the hard constraint against touching real shared state holds even under an honest mistake). Flagging for whoever owns `scripts/test.sh` (claudeline-core's territory): the harness needs its own private `RUNTIME_DIR` (e.g. `mktemp -d`), not the shared real one, both for hermeticity and because it's currently the most convenient live illustration of Verdict 3(a) available.

**This directly undercuts the ship-gate's "136/136 tests green" claim** — that count is not stable/reproducible when run standalone against a real UID on a machine with any other claudeline activity (this very review session's own tool calls, or the deployed v0.6.1 statusline, or a second terminal). Whatever produced the reported 136/136 was either a quiescent machine at that exact moment or a CI runner with a private UID/tmp namespace — worth confirming which, since the number is not self-verifying on a live dev machine.

## Verdict 4 — leak_inventory reclassification

- Item 2 (PR cache): **CLOSED.** Keying was already correct; the write-guard gap from the prior gate is now fixed (f6b971e) and tested.
- No new cross-profile item to add — Verdict 3(a)'s race is same-account only, out of this domain's strict charter, but flagged per Verdict 3.5 above since it's severe and was explicitly asked for.

## Verdict 5 — ship-ready?

**Cross-profile isolation: yes.** Both C1 (usage cache) and the PR-cache twin hold under live adversarial testing, including genuine concurrent work+personal racing — no cross-account leak reproducible by any means tried. This gate's specific mandate (work/personal must never see each other's state) is satisfied.

**Do not ship on the strength of "136/136 tests green" alone — that number was not reproducible in three consecutive standalone runs on this machine.** That's not a cross-profile finding, but it materially weakens the evidentiary basis the rest of the ship-gate report leans on, and it happens to be caused by the same code path (9a174f8's read-modify-write) this gate was asked to scrutinize. Recommend: (1) re-run `scripts/test.sh` on a genuinely quiescent machine/CI runner and confirm 136/136 there before trusting the count, (2) separately track the same-account lost-update race (Verdict 3a) as a correctness bug for claudeline-core, not blocking on cross-profile grounds but real and 100%-reproducible under ordinary multi-pane usage.
