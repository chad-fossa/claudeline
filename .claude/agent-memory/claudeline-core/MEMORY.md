# claudeline-core Memory

- [v0.7.0 re-gate pass 2](v070_regate2_pass2.md) — CURRENT STATE @ 9a174f8, 136/136 pass; SHIP; FIX3+folder fixed (live-verified); tmp-leak+jq-spawn still open; NEW concurrent RMW lost-update+false-freshness race in write_usage_window
- [v0.7.0 FINAL re-gate](v070_final_regate.md) — SUPERSEDED [?] by pass 2 above: @ a9ab2d0, 113/113 pass; CONDITIONAL ship (block on folder strip_ctrl gap, since fixed); contradiction resolved (other reviewers right, memory corrected); fetched_at-granularity + jq-spawn-count gaps found
- [v0.7.0 stdin-cache ship-gate verification](v070_stdin_cache_verification.md) — @ 2c32e0b (pre-fix-pass): 7/7 design decisions HONORED, 58/58 tests; finding (c) corrected by the re-gate above, see appended correction
- [Cache and account contract](cache_and_account_contract.md) — v0.7.0 schema (stdin-mirror, epoch resets_at, per-window rollover), sole-copy detect_account, PR cache account-keyed, tests now exist (58 cases)
- [Hardcoded hook path](hardcoded_hook_path.md) — SUPERSEDED [?]: hook itself deleted in v0.7.0, history only
- [v0.6.0 render/refresh cycle findings](v060_render_refresh_cycle.md) — SUPERSEDED [?]: entire subsystem it describes (hooks/, capture script, auto-capture) deleted in v0.7.0, history only
