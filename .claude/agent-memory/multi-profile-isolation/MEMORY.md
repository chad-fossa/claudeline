# multi-profile-isolation memory

## Findings
- [Ranked leak inventory](leak_inventory.md) — CRITICAL keychain single-slot, HIGH PR cache unkeyed, MEDIUM hardcoded hook path (compensated), env-default-to-work, install.sh single-profile blindness
- [Abandoned hashed-keychain attempt](abandoned_keychain_attempt.md) — v0.3.0→v0.3.1, empty mcpOAuth tokens caused 2-month silent personal-usage outage; never re-attempt without re-verifying #20553
- [Diff-test recipe](diff_test_recipe.md) — two-cache-file diff command to prove (not reason about) a leak

## Incidents
- [2026-07-06 incident](2026-07-06_incident.md) — personal statusline showed work's usage numbers; classic keychain-slot symptom; dotfiles-symlink deployment

## Design
- [Shipped v0.5.0 marker design](shipped_marker_design.md) — markers infer from `.claude.json` accountUuid (`=` shared, `?` differ), NOT a token probe; the probe was descoped — no `⚠`/`fetched_account` in the tree
- [v0.6.0 auto-capture trigger review](v060_auto_capture_trigger_review.md) — veto is one-sided (no lower bound, two-login-in-120s mis-capture); 120s empirically wrong (real gap +5s not 56s, sign flipped); `captured_for_uuid` must never suppress `?` or it regresses v0.5.0's safety property; `refresh_token_grant` undefined on cf/v0.6.0-file-first-credentials
- [v0.6.0 ship-gate final verification](v060_ship_gate_final_verification.md) — HEAD 7f71fbd, 6/7 conditions HONORED (118/118 tests pass); CRITICAL: install.sh's capture-script fix is uncommitted, auto-capture is DOA on any fresh install of the shipped commit; MEDIUM repeat-probe-storm on persistent identity mismatch; .bak/tmp-file perms not explicitly enforced
