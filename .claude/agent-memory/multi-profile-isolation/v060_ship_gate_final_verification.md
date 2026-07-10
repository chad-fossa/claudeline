---
name: v060-ship-gate-final-verification
description: Final step-9 ship-gate verification of v0.6.0 (HEAD 7f71fbd) against the 7 conditions set in v060_auto_capture_trigger_review — install.sh gap found uncommitted, veto/suppression/refresh conditions HONORED
metadata:
  type: project
---

2026-07-10, branch `cf/v0.6.0-file-first-credentials`, HEAD `7f71fbd`. Verified
each condition from [[v060_auto_capture_trigger_review]] against the actual
committed code (not just the diff) plus a live `bash scripts/test.sh` run
(118/118 pass).

**Verdicts:**
1. Two-sided veto — HONORED. `maybe_auto_capture()` (hooks/show-usage-limits.sh:268-269,275)
   computes `abs(mdat_epoch - profile_fetched_sec)` and vetoes `> window`;
   `window="${CLAUDELINE_CAPTURE_WINDOW_SECS:-30}"` (line 260). mdat parsing
   (`read_keychain_mdat_epoch`, lines 188-205) survives a real embedded NUL —
   empirically verified with `od -c`: bash command substitution does **NOT**
   strip the NUL (contrary to the code's own comment at lines 192-197 claiming
   it does) but `grep -a '"mdat"' | grep -a -o '[0-9]\{14\}Z'` still extracts
   the timestamp correctly regardless, because the anchored digit+Z regex
   stops before the NUL. Functionally correct; comment is factually wrong
   about *why* it works — worth a one-line fix, not a ship blocker.
2. `?` suppression — HONORED. `file_provenance_matches()` (statusline-command.sh:410-427)
   reads only `claudeline.verified_account_uuid` vs `.claude.json`'s
   `accountUuid`. Grepped the whole tree: `captured_for_uuid` appears **only**
   in the capture script's write path, tests, and docs/comments — zero reads
   in any render path. Unverified captures (probe timeout/non-200/unparseable)
   write the file without `verified_account_uuid` (capture-profile-session.sh:109-116),
   so `?` renders exactly as v0.5.0.
3. Identity probe — HONORED. `verify_capture_identity()` (capture-profile-session.sh:59-85):
   mismatch → script exits 1 *before* reaching the tmp/mv write block (lines 90-96,
   write block starts at 98) → no write, loud stderr naming both uuids/emails
   (never tokens), `/tmp/.claude_cred_capture_vetoed_<account>` artifact.
   Timeout/non-200/unparseable → `VERIFY_STATUS` stays `"unverified"` (default),
   falls into the unverified write branch. No local cache of the probe result
   anywhere in the file — every capture attempt hits `/api/oauth/profile` fresh,
   so it can't be spoofed by a stale cache at the code level.
4. Rotation discipline — PARTIAL.
   - `.bak` before POST: HONORED (`cp` at line 139, before the `curl -X POST`
     at line 145).
   - `.bak` 600 perms: **not explicitly enforced**. `cp` without `-p` inherits
     the source file's mode bits as filtered by umask — empirically verified
     (`stat` after `cp`) that a 600 source produces a 600 `.bak` under normal
     umasks (022, 000), so it works in the common case, but there's no
     `chmod 600 "${creds_file}.bak"` in the code and no test in scripts/test.sh
     asserts `.bak`'s permission mode (grepped — only existence/content checks
     at lines 249, 277, 292, 482). If `.credentials.json` were ever created
     with looser permissions than 600, `.bak` — which holds a live, unexpired
     refresh token — would silently inherit that.
   - tmp+chmod-600-before-mv: HONORED for both `refresh_token_grant` (hook
     lines 173-178) and `capture-profile-session.sh` (lines 98-119) — chmod
     does happen before mv. Residual, lower-severity note: `jq ... > tmp_file`
     creates the tmp file at the process's default (umask-derived) mode
     *before* the `chmod 600` runs, so there's a brief window where a tmp
     file holding a live access/refresh token exists at a more permissive
     mode. Same pattern in both call sites. Not tested either.
   - No silent keychain fallback on file-refresh-failed: HONORED —
     `get_token()`'s refresh-failure paths (hook lines 73-86) always `return 1`
     from inside the `-n "$access_token"` branch, never falling through to
     the Darwin keychain branch below.
   - Distinct loud artifact: HONORED — `/tmp/.claude_cred_refresh_failed_<account>`
     (handle_refresh_failure) vs `/tmp/.claude_cred_capture_vetoed_<account>`
     (both timing-veto and identity-mismatch-veto share this second name —
     intentional per README, not a bug, but worth knowing when debugging:
     same artifact path for two different veto *reasons*, distinguished only
     by artifact *content*).
5. `ACCOUNT_ASSUMED=1` refuses every write path — HONORED. Checked all three:
   `refresh_token_grant` (hook lines 117-120), `maybe_auto_capture` (hook
   line 243, returns before ever reaching a write), `capture-profile-session.sh`
   (lines 23-26). The auto-capture→capture-script handoff sets
   `CLAUDE_CONFIG_DIR="$_CREDS_DIR"` explicitly on invocation, so even in a
   hypothetical reachable-while-assumed case the child's own `detect_account()`
   would see a real path, not unset — moot in practice since (2) already
   gates it upstream, but confirms no double-negative bypass.
6. `refresh_token_grant` — HONORED, now defined (hook lines 113-182,
   previously the memory'd gap: undefined on this branch) and covered by
   200-with-rotation / 200-without-rotation / 500 / ACCOUNT_ASSUMED / lock-held
   test cases, all passing.

7. **NEW — not anticipated by the original design review:**
   - **CRITICAL for ship-readiness (not a security defect, a functionality
     gap): install.sh at committed HEAD 7f71fbd does NOT ship
     `scripts/capture-profile-session.sh`.** `git status` shows the fix
     (mkdir scripts/, curl-download it, chmod +x, plus matching manual-install
     README steps) sitting **uncommitted** in the working tree
     (`git diff HEAD -- install.sh` confirms). `resolve_capture_script()`
     (hook lines 213-220) falls through to `$HOME/.claude/scripts/capture-profile-session.sh`,
     which also won't exist on a fresh install of the shipped commit — so on
     ANY fresh `curl | bash` install of 7f71fbd, `maybe_auto_capture` will
     loudly skip ("capture script not found") on every single invocation,
     forever. The entire headline feature of this release ("`/login` is all
     you have to do") is non-functional end-to-end from the documented
     install path as currently committed. The fix already exists locally —
     it just needs to be committed before this ships.
   - **MEDIUM — repeat-probe-storm on persistent identity mismatch.**
     `maybe_auto_capture` discards the capture script's exit code (hook line
     293, output redirected to /dev/null, return value never checked) and
     always `return 0`. On an identity-mismatch veto, the capture script
     exits 1 *without* writing `captured_login_at` — so the next hook
     invocation (every SessionStart, every compact, every manual `/usage`)
     sees `profile_fetched_at != captured_login_at` again, re-evaluates the
     (unchanged, still-matching) timing window, and re-invokes the capture
     script — which makes a fresh live HTTPS call to
     `https://api.anthropic.com/api/oauth/profile` every time. This repeats
     indefinitely for as long as two profiles' logins sit within the
     corroboration window of each other but resolve to different accounts
     (a fully plausible steady state, not just a transient race) — hammering
     Anthropic's API on a cadence tied to session starts, not something the
     original timing-veto-focused review considered. Low urgency (bounded by
     session-start/compact frequency, not a tight loop) but worth a follow-up:
     either check the capture script's exit code and skip re-probing on a
     repeated identity-mismatch until the login stamp actually changes, or
     stamp something on mismatch too so the retrigger check short-circuits.
   - **LOW — no integrity check on the resolved capture script before exec.**
     `resolve_capture_script()` + `bash "$capture_script"` (hook lines
     213-220, 293) execute whatever file sits at
     `${_CREDS_DIR}/scripts/capture-profile-session.sh` (or the `$HOME/.claude`
     fallback) with no ownership/writability check first. `_CREDS_DIR` is
     derived from `CLAUDE_CONFIG_DIR`, which the profile already fully trusts
     (it's the credentials store itself), so this isn't a new trust boundary
     — flagging for completeness, not blocking.

**Test suite:** `bash scripts/test.sh` — 118/118 pass, confirms the 31
identity/auto-capture cases added in this pass all hold as claimed.

**Overall verdict given:** not ship-ready as currently committed at
7f71fbd — one CRITICAL functionality gap (install.sh) sitting uncommitted
in the working tree, trivial to fix (commit the existing working-tree diff).
Once that's committed: ship with the MEDIUM repeat-probe-storm and the
.bak-permission / tmp-file-write-window gaps in condition 4 tracked as
non-blocking follow-ups, not gates — none of them regress the core
multi-profile-isolation invariant (conditions 1, 2, 3, 5, 6 all HONORED
against real code, not just the diff).
