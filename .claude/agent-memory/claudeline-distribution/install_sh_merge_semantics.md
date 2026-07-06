---
name: install-sh-merge-semantics
description: install.sh's jq merge into settings.json — what it does and doesn't handle
metadata:
  type: reference
---

install.sh (confirmed 2026-07-06) downloads three artifacts (statusline-command.sh,
hooks/show-usage-limits.sh, skills/usage/SKILL.md) into `$HOME/.claude`, then merges
into settings.json:
- Existing settings.json: `cp` to `.bak`, then `jq` overwrites only `.statusLine` and
  `.hooks.SessionStart` keys wholesale (lines 46-68).
- No settings.json: `jq -n` writes both keys plus `$schema` from scratch (lines 71-89).

Non-idempotent by design: every run re-overwrites the same two keys regardless of
prior content. No deletion path — a key install.sh once wrote but no longer needs
is never cleaned up. No upgrade detection at all — same merge every time, no version
check, no diff of what already exists.

ZERO multi-profile awareness: never targets `~/.claude-personal`, never reads or
respects `CLAUDE_CONFIG_DIR`. Always writes to `$HOME/.claude` only. This is a real
gap relative to claudeline-core, which is built entirely around
`CLAUDE_CONFIG_DIR`-based multi-account isolation (see [[multi_profile_checklist]]).

Darwin+Linux only (uname gate, lines 20-26); jq+curl required as deps.
