# multi-profile-isolation memory

## Current state (v0.7.0, re-gated at 9a174f8, 2026-07-10)
- [v0.7.0 re-gate 2](v070_regate2.md) — SECOND blocking re-gate, delta f6b971e..9a174f8. Cross-profile isolation CONFIRMED HOLDING under live adversarial + concurrent testing (work+personal raced simultaneously, zero cross-contamination, filename keying makes it structurally impossible). PR-cache guard (f6b971e) CLOSES the prior gate's open item, live-verified writes zero files under guessed identity. NEW (out-of-charter but explicitly asked for): 9a174f8's per-window read-modify-write has a same-account lost-update race, 100% reproducible (40/40) under two concurrent same-profile writers — not a cross-profile leak (accounts can't collide, confirmed live) but a real data-integrity regression, flagged for claudeline-core. Also found: `scripts/test.sh`'s claimed "136/136 green" is NOT reproducible standalone on this machine (3 consecutive runs: 3, 12, 9 distinct failures) because its `RUNTIME_DIR` is the real shared UID-keyed path, not isolated — a live, unplanned illustration of the same race.
- [v0.7.0 fix-pass re-gate](v070_fixpass_regate.md) — FIRST blocking re-gate of ad4f8c0+a9ab2d0: usage-cache `ACCOUNT_ASSUMED` guard confirmed fixed; found the PR-cache gap that f6b971e later closed (see above).
- [v0.7.0 stdin-rate-limits review](v070_stdin_rate_limits_review.md) — CRITICAL keychain leak CLOSED BY CONSTRUCTION (hook deleted, verified live)
- [Ranked leak inventory](leak_inventory.md) — items 1/2/3 all CLOSED (item 2 closed as of f6b971e/this gate), item 4 usage-cache write-guard FIXED, item 5 STILL LIVE (install.sh single-profile by construction, unchanged)

## Findings (pre-v0.7.0 history — see superseded banners in each file)
- [Abandoned hashed-keychain attempt](abandoned_keychain_attempt.md) — v0.3.0→v0.3.1, empty mcpOAuth tokens caused 2-month silent personal-usage outage; never re-attempt without re-verifying #20553 (still relevant background even though the keychain path itself is now deleted)
- [Diff-test recipe](diff_test_recipe.md) — [SUPERSEDED] old two-cache-file diff command invoked the now-deleted hook; replacement recipe is in v070_stdin_rate_limits_review.md

## Incidents
- [2026-07-06 incident](2026-07-06_incident.md) — personal statusline showed work's usage numbers; classic keychain-slot symptom; dotfiles-symlink deployment; root cause now closed by construction as of v0.7.0

## Design (pre-v0.7.0 history — see superseded banners in each file)
- [Shipped v0.5.0 marker design](shipped_marker_design.md) — [PARTIALLY SUPERSEDED] `=` marker survives unchanged (now cosmetic-only per v0.7.0 review); `?` marker is deleted, no replacement
- [v0.6.0 auto-capture trigger review](v060_auto_capture_trigger_review.md) — [SUPERSEDED] entire capture flow deleted in v0.7.0
- [v0.6.0 ship-gate final verification](v060_ship_gate_final_verification.md) — [SUPERSEDED] entire credential subsystem this reviewed deleted in v0.7.0
