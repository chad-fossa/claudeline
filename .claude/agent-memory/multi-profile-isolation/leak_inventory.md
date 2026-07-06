---
name: leak-inventory
description: Ranked cross-profile state-bleed inventory for claudeline-core (statusline + usage hooks)
metadata:
  type: project
---

Ranked, worst first, verified against code at /Users/chadfurman/code/claudeline on 2026-07-06:

1. **CRITICAL — keychain single-slot (macOS only).** `hooks/show-usage-limits.sh` line 41 reads `security find-generic-password -s "Claude Code-credentials"` — one global entry, not per `CLAUDE_CONFIG_DIR`. Last `/login` wins across profiles. Upstream: anthropics/claude-code#20553 (re-verify still open before trusting this framing — do not assume from memory). Code has an inline comment (lines 36-39) documenting this constraint explicitly rather than working around it. Linux is NOT affected: line 47 reads `${_CREDS_DIR}/.credentials.json` (a file under `$CLAUDE_CONFIG_DIR`), properly per-profile — the clean reference model.
2. **HIGH — PR cache not account-keyed.** `statusline-command.sh` line 249: `local cache="/tmp/.claude_pr_cache_${repo_name}"` — keyed by repo name only, no account/`ACCOUNT_ID` component. Same repo open under both profiles shares one cache entry. Confirmed still true in this repo's `get_pr_number()` as of 2026-07-06. Note: per domain-bootstrap researcher notes, the user's *deployed* dotfiles copy is reportedly ahead of this repo and already keys this by `_${ACCOUNT_ID}` — if asked to fix this, check the deployed copy for the already-written fix before writing a new one.
3. **MEDIUM — hardcoded hook path.** `statusline-command.sh` line 76: `readonly USAGE_REFRESH_HOOK="$HOME/.claude/hooks/show-usage-limits.sh"` — always resolves to the work-profile hook path, never `$CLAUDE_CONFIG_DIR`-relative. Compensated: that hook re-derives its own `ACCOUNT_ID`/`_CREDS_DIR` internally from `CLAUDE_CONFIG_DIR` (lines 6-12), so despite running "the work copy of the script," it still writes to the correct per-account cache file (`/tmp/.claude_usage_limits_${ACCOUNT_ID}.json`). Verified this compensation holds in current code — the hook does not trust its own invocation path for identity, only the env var.
4. **Env-detection defaults to "work."** Both scripts: `statusline-command.sh` lines ~51-55 and `hooks/show-usage-limits.sh` lines ~6-12 test `CLAUDE_CONFIG_DIR == *"claude-personal"*`, else default to `"work"`/`$HOME/.claude`. Any launch without `CLAUDE_CONFIG_DIR` set (desktop app launches, background jobs, resumed sessions missing the shell alias) silently renders as work profile.
5. **install.sh / settings-example.json are single-profile by construction.** `install.sh` line 8 hardcodes `CLAUDE_DIR="$HOME/.claude"`; `settings-example.json` hardcodes `~/.claude/...` command paths (lines 5, 11, 15). No path in either file ever targets `~/.claude-personal`. A second profile is entirely manual user setup — install.sh has zero multi-profile awareness and no upgrade/reconciliation story.

See [[abandoned-keychain-attempt]] for the history of item 1, [[diff-test-recipe]] for how to verify any of these live, and [[2026-07-06-incident]] for the live incident that seeded this memory.
