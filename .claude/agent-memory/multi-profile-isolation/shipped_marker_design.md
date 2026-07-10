**[PARTIALLY SUPERSEDED as of v0.7.0, 2026-07-10]** `unverifiable_marker()`/`?` described below is DELETED — the whole credential-provenance concept it flagged no longer exists (no fetch, no capture, nothing to be unverified about). `profile_uuid_state()`/`shared_login_marker()`/dim `=` SURVIVE unchanged (`statusline-command.sh:432-455`) but per [[v070_stdin_rate_limits_review]] Verdict 2, `=` is now cosmetic/informational only — it never covered the residual leak that does still exist post-v0.7.0, and there is no replacement for what `?` used to warn about. Do not assume `?` exists; grep is empty.

# Shipped v0.5.0 marker design (the descoped subset)

v0.5.0 shipped the endpoint-independent subset, NOT the full token-identity probe.
The spec drafted a `fetched_account.verified` probe + `⚠` mismatch marker; that probe
was permission-blocked during research and **descoped** (CHANGELOG Known-issues). Do not
assume `⚠` or `fetched_account` exist — grep is empty.

What actually renders (statusline-command.sh L371-399):
- `profile_uuid_state()` compares `.oauthAccount.accountUuid` in `~/.claude/.claude.json`
  vs `~/.claude-personal/.claude.json` → `equal | differ | unknown | single`.
- `shared_login_marker()` → dim `=` after the account label when `equal` (both profiles
  same login; numbers legitimately identical).
- `unverifiable_marker()` → dim `?` after the usage segment (macOS only) when `differ`
  (numbers may belong to the wrong profile).
- Assumed-account (unset `CLAUDE_CONFIG_DIR`) → dimmed account label.

Inference-from-`.claude.json`, never a live token probe. Re-attempting the probe needs a
verified OAuth identity endpoint first (see [[abandoned_keychain_attempt]] for the cost of
shipping an unverified auth assumption).
