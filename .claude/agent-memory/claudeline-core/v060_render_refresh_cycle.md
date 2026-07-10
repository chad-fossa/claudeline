---
name: v060-render-refresh-cycle
description: v0.6.0 file-first-credentials — ship-gate findings, fix-pass verification (7929916), and final re-verification (98416f1). Self-deadlock RESOLVED by c2a5de5's lock hand-off; RUNTIME_DIR ownership gating (0609b9d) doesn't break the render/refresh cycle. Ship-ready as of 98416f1, 197/197.
metadata:
  type: reference
---

## FINAL: re-verified 2026-07-10, HEAD `98416f1`, `PASS: 197 FAIL: 0` — SHIP-READY

The CRITICAL auto-capture self-deadlock documented below (found against `7929916`) is
**resolved** by `c2a5de5` ("resolve self-deadlock via explicit lock hand-off"), confirmed live
against the *real* (non-stubbed) `capture-profile-session.sh`, not just by reading the diff:

- **Happy path** — `maybe_auto_capture` sets `CLAUDELINE_CRED_LOCK_HELD=1` in the child's env
  (hooks/show-usage-limits.sh:521-524); the child's `acquire_cred_lock_unless_parent_holds()`
  (capture-profile-session.sh:67-70) skips its own acquire/release when that var is set, so the
  parent's held lock is the only one in play — no more self-collision. Repro: extracted
  `maybe_auto_capture` + deps, ran against the real script under a realistic
  `CLAUDE_CONFIG_DIR` — `.credentials.json` IS written, `verified_account_uuid` stamped, lock
  released cleanly.
- **Exit-code contract verified live**, all three branches:
  - `0` = captured → sentinel recorded (repro above).
  - `2` = identity mismatch → sentinel recorded (prevents probe-storm re-verifying a known-bad
    session) — repro'd with a mismatched-uuid profile-probe stub, `.claude_cred_capture_vetoed_*`
    artifact written, sentinel present.
  - `1` = transient (unreadable Keychain, or the *parent's own* `acquire_cred_lock` losing to a
    genuinely unrelated lock-holder) → **no sentinel**, next render for the same login retries
    and succeeds once the transient condition clears. Repro'd both ways: (a) Keychain stub
    returning empty → child exits 1, stderr now flows through (no longer swallowed by
    `>/dev/null 2>&1` — only stdout is redirected now, `hooks/show-usage-limits.sh:524`), no
    sentinel, second render succeeds once Keychain stub fixed; (b) an unrelated process holding
    `.claude_cred_lock_<account>` before `maybe_auto_capture` even runs → parent's own
    `acquire_cred_lock || return 0` fails first, child never invoked, no sentinel, second render
    (lock freed) succeeds.
- Manual (non-auto) invocation of `capture-profile-session.sh` is unaffected — `CLAUDELINE_CRED_LOCK_HELD`
  is unset in that path, so it still acquires/releases the lock itself exactly as before.

**`0609b9d`'s RUNTIME_DIR ownership gating (`verify_runtime_dir`) doesn't break the
render/refresh cycle.** Every write/read site under `RUNTIME_DIR` (cache read/write,
cred-lock acquire, PR cache, background-refresh lock, malformed-creds artifact) is now gated on
`RUNTIME_DIR_SAFE` (set once by `verify_runtime_dir`: unsafe only if the path is a symlink,
isn't a directory, or isn't owned by this uid). In the normal case — a freshly `mkdir -p -m 700`'d
dir this process just created and owns — `RUNTIME_DIR_SAFE=1` and every function behaves
identically to pre-gating. Confirmed live: full statusline render (`echo '{...}' | bash
statusline-command.sh`) against a clean `RUNTIME_DIR` renders normally, exit 0, no behavior
change. `197/197` includes 3 new symlink-swap tests (statusline/hook/capture all refuse loudly,
leave the symlink untouched, write nothing into the symlink target) plus 2 identical-copy
assertions across all three scripts.

**Remaining low-severity items, not blocking**: the reverse provenance-staleness edge (cache
says `verified_match` but the file was since swapped to a mismatched identity within the 300s
TTL) — per `98416f1`'s commit message ("docs: reverse provenance-staleness edge...") this now
appears to be documented; not re-verified in this pass but flagged as addressed. Keychain-read
timeouts in `read_keychain_mdat_epoch`/capture script/`get_token`'s fallback remain unwrapped
by any `--timeout`-equivalent — pre-existing, low-severity, not part of this gate.

**Ship verdict: YES**, all 5 points satisfied — reap margin (120s vs ~15s), lock_held benign in
both refresh AND (now) auto-capture paths, cold-start no fabrication, provenance cache-stamped
render-pure, keychain-fallback instrumented. `PASS: 197 FAIL: 0`.

---

## Fix-pass verification, 2026-07-10, branch `cf/v0.6.0-file-first-credentials`, HEAD `7929916` (historical — superseded above)

Original gate (HEAD `7f71fbd`) filed: HIGH cred-lock no staleness reaper + auto-capture
lock-held silent no-op; MEDIUM cold-start fabricated 0% render; render-purity
(provenance recomputed per-render); keychain-fallback instrumentation gap.

**Resolved and verified correct:**
- **Cred-lock staleness reaper** — `acquire_cred_lock()` (hooks/show-usage-limits.sh:180-196,
  byte-identical copy in scripts/capture-profile-session.sh:39-55) reaps a lock dir >120s old
  before attempting `mkdir`. 120s vs the documented ~15s `/usage` worst-case sequential-curl
  chain (CHANGELOG "synchronous worst case ≈15s") is ample margin — won't falsely reclaim a
  live, slow-but-normal operation, only a genuinely abandoned one (SIGKILL, laptop sleep).
  EXIT trap saves/restores the caller's prior trap rather than clobbering it.
- **lock_held is a benign silent skip in the *refresh* path** — `resolve_file_credentials()`
  sets `TOKEN_SOURCE=lock_held` when `refresh_token_grant` sees the lock held (hooks/
  show-usage-limits.sh:136-139); `main()` explicitly excludes `lock_held` from both the
  refresh-failure artifact/cache-mutation path and the stderr message (hooks/
  show-usage-limits.sh:609-617). Test-verified end-to-end: no `.claude_cred_refresh_failed_*`
  artifact, cache byte-unchanged, zero stderr (scripts/test.sh "lock_held e2e" block).
- **Cold-start fabrication fixed** — `handle_refresh_failure()` no longer has an else-branch
  that `jq -n`'s a bare `{token_source:...}` cache when none exists (hooks/
  show-usage-limits.sh:591-595: only merges into `$CACHE_FILE` `if [[ -f ]]`). Statusline's
  `get_usage_limits()` gates on `fetched_at` being non-empty *before* trusting any `// 0`
  default (statusline-command.sh:169), via a `\x01`-delimited `read` that — verified by hand —
  correctly preserves an empty *leading* field (`fetched_at`), unlike `@tsv`'s real tab
  delimiter which `read`'s IFS-whitespace splitting would have swallowed. All three render
  states (absent cache / cold-start failure / warm-cache failure) walked and test-verified,
  no fabricated numbers in any of them.
- **Render-purity / provenance** — `compute_provenance()` (hooks/show-usage-limits.sh:343-358)
  runs once at cache-write time, stamps `provenance` into the cache JSON. Statusline reads it
  in the *same* single jq/`\x01`-read as everything else in `get_usage_limits()`
  (statusline-command.sh:152-163) — `file_provenance_matches()` is gone from
  statusline-command.sh entirely (confirmed via grep, zero references left). One accepted
  staleness edge, documented in README: a provenance value can lag up to the 300s TTL behind
  the real file state (e.g. a just-verified capture keeps `?` up for up to 300s more). A
  **second, undocumented** edge exists in the same direction reversed: if the credentials file
  is swapped to a different/mismatched identity *after* a `verified_match` was cached, the `?`
  marker can incorrectly stay suppressed for up to that same 300s — worth flagging in README's
  known-issues alongside the documented direction, not yet done. Low severity, bounded by TTL.
- **Keychain-fallback instrumentation** — `log_malformed_credentials()` added (hooks/
  show-usage-limits.sh:98-102): file-present-but-broken now gets one loud stderr line +
  `.claude_cred_malformed_<account>` artifact before falling to keychain. Absent-file silent
  fallback is unchanged (correct — that's the common/expected case, not a bug state).

**At the time of this HEAD (`7929916`) — NOT resolved, new CRITICAL regression, ship-blocking.
RESOLVED by `c2a5de5` — see "FINAL" section at the top of this file for the live-repro
confirmation.**

`maybe_auto_capture()` self-deadlocks on the cred lock on *every real invocation*, making
"/login is all you have to do" — this release's headline feature — permanently non-functional
on macOS.

Root cause: commit 52a6ca2 ("converge retries with a per-login sentinel, remove TOCTOU") added
`acquire_cred_lock`/`release_cred_lock` to `scripts/capture-profile-session.sh` so a *manual*
capture run can't race an in-flight refresh (capture-profile-session.sh:95-98). But
`maybe_auto_capture()` in the hook already holds that exact same lock (hooks/
show-usage-limits.sh:461, `acquire_cred_lock || return 0`) for the *entire* duration it shells
out to that same script as a real subprocess (hooks/show-usage-limits.sh:508,
`CLAUDE_CONFIG_DIR="$_CREDS_DIR" bash "$capture_script" >/dev/null 2>&1` — synchronous, not
backgrounded). The lock is `mkdir`-based and process-external, not reentrant: the child's own
`acquire_cred_lock()` call sees the dir already exists, isn't stale (parent just created it),
`mkdir` fails, child prints "capture skipped: credential lock held..." to stderr and `exit 1`
— but that stderr is swallowed by the `>/dev/null 2>&1` at the invocation site, so **the
failure is completely invisible**. Worse: `attempt_auto_capture()` calls
`record_capture_attempt "$profile_fetched_at"` unconditionally after the invocation regardless
of the child's exit code (hooks/show-usage-limits.sh:509) — poisoning the probe-storm-guard
sentinel for that exact login value, so even repeated statusline renders won't retry; only a
genuinely new `/login` (new `profileFetchedAt`) gets another (also doomed) attempt.

Confirmed by direct repro (not by reading): extracted `maybe_auto_capture`+deps standalone,
ran against the *real* (non-stubbed) `capture-profile-session.sh` with realistic
`CLAUDE_CONFIG_DIR`/`detect_account` — hook prints "auto-capturing session for..." (passed the
veto window, found the script) but no `.credentials.json` is ever written. Isolated repro of
just the child invocation with the lock pre-held (simulating the parent's hold) reproduces the
exact "capture skipped: credential lock held..." exit-1 every time.

**Why the test suite (159/159 green) didn't catch this**: the `maybe_auto_capture` test block
(scripts/test.sh ~line 505) stubs `capture-profile-session.sh` with a two-line fake that just
`touch`es a sentinel file — it never calls `acquire_cred_lock`, so it never exercises the
parent/child lock nesting. The *separate* "manual capture blocked while lock held" test
(scripts/test.sh:871-882) only checks the standalone scenario (a lock pre-held by something
else, e.g. a real concurrent refresh) — it never runs through `maybe_auto_capture` itself. The
two code paths that would together reproduce the bug (real script + real
`maybe_auto_capture`-held lock) are never combined in any test. This is the exact "zero test
coverage would have shipped a regression a test could have caught" case this expert is
supposed to flag.

**Fix options** (not yet implemented, for whoever picks this up): (a) simplest — have
`maybe_auto_capture` NOT hold the lock itself around the invocation; let
`capture-profile-session.sh`'s own `acquire_cred_lock` be the only acquisition point (drop
hooks/show-usage-limits.sh:461's wrap, keep the child's). Loses the "auto-capture and an
in-flight refresh can't race" guarantee the comment at hooks/show-usage-limits.sh:433-434
claims — would need to re-derive that guarantee some other way (e.g. check-then-invoke without
holding across the exec). (b) pass a flag/env var telling the child "caller already holds the
lock, skip your own acquisition" — reintroduces a TOCTOU-shaped trust boundary between
processes, same shape as what 52a6ca2 explicitly set out to remove. (c) make the lock
reentrant via a token file recording the holding PID + a counter — most robust, most invasive.
Recommend (a) with a follow-up on the race guarantee, but flag for discussion before
implementing — this is the kind of design call worth confirming with whoever owns the
capture-flow architecture.

**PASS line**: `scripts/test.sh` → `PASS: 159  FAIL: 0` (full run, 2026-07-10). All 159 green;
none of them exercise the self-deadlock above.

Related: [[cache-and-account-contract]], [[hardcoded-hook-path]]
