---
name: v060-auto-capture-trigger-review
description: Adversarial review of the v0.6.0 auto-capture trigger (profileFetchedAt value-delta + keychain-mdat veto) — one-sided veto defect found, empirical timing recalibrated live
metadata:
  type: project
---

2026-07-10 consult on the not-yet-built v0.6.0 auto-capture design (branch
`cf/v0.6.0-file-first-credentials`, executor mid-build). Trigger: capture
fires when `.claude.json`'s `.oauthAccount.profileFetchedAt` differs from
`claudeline.captured_login_at` in `.credentials.json`. Corroboration veto:
abort if keychain "Claude Code-credentials" mdat postdates profileFetchedAt
by >120s.

**CRITICAL — veto is one-sided, not symmetric.** It only bounds how much
LATER the keychain write can be than the stamp; it has no lower bound. Two
logins in different profiles within the window (P logs in, Q logs in ~90s
later in the other profile — exactly the workflow this tool exists for) lets
Q's fresh keychain token get captured into P's `.credentials.json` under P's
own legitimate `profileFetchedAt` stamp, no adversarial timing required. A
delayed/retried profile-fetch produces the same hole via latency instead of
concurrency. Fix: bound `abs(keychain_mdat - profileFetchedAt)`, not just the
postdate direction — though even bidirectional bounding only shrinks the
race window, it can't close it; timestamp proximity on a single shared
mutable resource (the keychain slot) can't prove causal ownership between
two independent per-profile event streams. No amount of window-tuning
substitutes for an identity probe (which remains descoped — see
[[shipped_marker_design]]).

**Empirical timing was wrong in the brief — recomputed live, don't trust
manual eyeballing.** Pulled the real numbers instead of reasoning about them:
personal `.claude.json` `profileFetchedAt` = `1783657301823` ms =
2026-07-10 04:21:41 UTC. Keychain "Claude Code-credentials" mdat (metadata
only, no `-w`) = 2026-07-10 04:21:46 UTC. Actual gap: keychain **postdates**
the stamp by **+5s** — opposite sign and ~10x smaller magnitude than the
brief's claimed "keychain precedes by ~56s." Both stamps are plainly
local-system-clock-derived (no server-clock indirection artifact visible),
so skew itself isn't the risk — but a single manual sample was wrong in both
sign and magnitude, which means the "120s chosen given the observed 56s gap"
justification doesn't hold. Before finalizing any window: script the
measurement across several real `/login` events in both profiles; don't
reuse this one data point either — n=1 twice now, two different answers.

Confirmed the trigger's core premise: routine `.claude.json` churn does NOT
touch `profileFetchedAt`. Personal `.claude.json` mtime was 04:58:31 UTC
(37 min after the stamp) with the same stamp value still in place — mtime
noise genuinely can't fire this trigger. That part is sound.

**Regression risk — `captured_for_uuid == profile uuid` must never suppress
`?`.** Checked shipped code: `unverifiable_marker()` (statusline-command.sh
L371-398) keys purely on `profile_uuid_state()`, comparing
`.oauthAccount.accountUuid` across both profiles' `.claude.json` — no
`captured_for_uuid` mechanism exists yet anywhere in the tree (grepped,
empty). As specified, a mis-capture trivially satisfies
`captured_for_uuid == profile_uuid` by construction — the capture code
stamps its OWN profile's uuid, it never verifies the captured token's real
owner. If that equality is allowed to suppress `?` (replacing or OR'd
against the existing differ-check), a mis-capture converts what used to be
a visible `?` into a confidently-wrong render — regressing the exact
property v0.5.0 shipped to guarantee (CHANGELOG: "surfaces this instead of
rendering silently wrong/unverifiable numbers"). Checked for a downstream
tripwire: `fetch_usage()`'s API response carries only `five_hour`/
`seven_day` utilization, no account-identity field — nothing to cross-check
capture correctness against after the fact. **Condition, not optional:**
keep `?` keyed solely on the existing capture-independent
`profile_uuid_state()`; `captured_for_uuid` may log/debug, never suppress.

**Build-state note:** `refresh_token_grant` is called (hooks/show-usage-limits.sh,
in the uncommitted `get_token()` diff on `cf/v0.6.0-file-first-credentials`)
but not defined anywhere in the file — currently fails safe (bash
function-not-found → falls through to `file-refresh-failed`) but must be
defined before merge. Also noted: `~/.claude-personal/.credentials.json`
does not exist yet — personal profile is 100% keychain-sourced today, so
auto-capture's first write for that profile is a blind first write with no
prior `captured_login_at` baseline to sanity-check drift against.

**Verdict given to Chad:** ship with conditions, not as specified — fix the
veto's one-sidedness, recalibrate the window from real multi-sample data
(not the contradicted 56s figure), and hard-decouple `?` suppression from
capture provenance. See [[abandoned_keychain_attempt]] for why this class of
change gets extra scrutiny (2-month silent outage precedent), and
[[pattern-claudeline-credential-writes]] (change-factory-orchestrate-decider
memory) for the standing low-confidence-by-policy gate on all credential-write
diffs in this repo.
