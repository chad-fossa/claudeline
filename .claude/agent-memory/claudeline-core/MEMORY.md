# claudeline-core Memory

- [Cache and account contract](cache_and_account_contract.md) — usage-cache schema, account-detection rule, get_token() churn history, PR cache now account-keyed (resolved), zero tests
- [Hardcoded hook path](hardcoded_hook_path.md) — RESOLVED: statusline's hook path is now CLAUDE_CONFIG_DIR-aware via resolve_usage_refresh_hook()
- [v0.6.0 render/refresh cycle findings](v060_render_refresh_cycle.md) — SHIP-READY as of 98416f1 (197/197): auto-capture self-deadlock (found @7929916) fixed by c2a5de5's lock hand-off, live-repro confirmed; RUNTIME_DIR ownership gating (0609b9d) doesn't break the cycle
