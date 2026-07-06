---
name: hardcoded-hook-path
description: statusline hardcodes the background-refresh hook path to $HOME/.claude, bypassing CLAUDE_CONFIG_DIR
metadata:
  type: reference
---

Confirmed against code 2026-07-06.

`USAGE_REFRESH_HOOK="$HOME/.claude/hooks/show-usage-limits.sh"` (statusline-command.sh:76) is hardcoded — it does not respect `CLAUDE_CONFIG_DIR`. Ranked MEDIUM severity in the domain-bootstrap research, mitigated (not eliminated) by the fact that the hook itself re-derives `ACCOUNT_ID`/`_CREDS_DIR` at runtime from `CLAUDE_CONFIG_DIR` (hooks/show-usage-limits.sh:7-13), so even though the *invoking path* is fixed to the work install, the *credentials/cache it acts on* still follow the caller's env. Net effect: works correctly as long as `$HOME/.claude/hooks/show-usage-limits.sh` is the canonical hook copy for all profiles (true today per install.sh, owned by claudeline-distribution) — would break if a profile needed a genuinely different hook version.

Low confidence overall on this cluster: only 7 commits touch it (below the ~30-commit weak-signal floor per team's Init convention), so treat conclusions here as provisional pending more history.

Related: [[cache-and-account-contract]]
