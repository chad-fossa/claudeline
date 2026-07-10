---
name: hardcoded-hook-path
description: statusline hardcodes the background-refresh hook path to $HOME/.claude, bypassing CLAUDE_CONFIG_DIR
metadata:
  type: reference
---

**SUPERSEDED 2026-07-10 [?]** — v0.7.0 (2c32e0b) deletes `hooks/show-usage-limits.sh`, `resolve_usage_refresh_hook()`, and `USAGE_REFRESH_HOOK` outright; usage now arrives on stdin, so there is no hook path left to be hardcoded or profile-aware. This entry is pure history below.

Confirmed against code 2026-07-06.

**RESOLVED, confirmed 2026-07-10** — as of the current code, `statusline-command.sh` no longer hardcodes the hook path. `resolve_usage_refresh_hook()` (statusline-command.sh:91-98) prefers `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/show-usage-limits.sh` and only falls back to the work install (`$HOME/.claude/hooks/...`) if the profile-local one isn't executable; `USAGE_REFRESH_HOOK` (statusline-command.sh:99) is set from that. This fix predates the v0.6.0 diff (not part of it) — the account-scoping gap this memory originally described is closed. Superseded entry below kept for history [?].

~~`USAGE_REFRESH_HOOK="$HOME/.claude/hooks/show-usage-limits.sh"` (statusline-command.sh:76) is hardcoded — it does not respect `CLAUDE_CONFIG_DIR`.~~ Ranked MEDIUM severity in the domain-bootstrap research at the time; mitigation reasoning (hook re-derives `ACCOUNT_ID`/`_CREDS_DIR` from `CLAUDE_CONFIG_DIR` regardless of invoking path) no longer needed now that the path itself is profile-aware.

Low confidence overall on this cluster: only 7 commits touch it (below the ~30-commit weak-signal floor per team's Init convention), so treat conclusions here as provisional pending more history.

Related: [[cache-and-account-contract]], [[v060-render-refresh-cycle]]
