---
name: install-sh-merge-semantics
description: install.sh's jq merge into settings.json — what it does and doesn't handle
metadata:
  type: reference
---

install.sh (confirmed 2026-07-06; artifact list updated 2026-07-10 for v0.6.0)
downloads into `$CLAUDE_DIR` (`${CLAUDE_CONFIG_DIR:-$HOME/.claude}` — honors
`CLAUDE_CONFIG_DIR` since v0.5.0, contradicting the "ZERO multi-profile
awareness" / "Always writes to $HOME/.claude only" note below, which is
STALE — see [?] flag there). Artifacts as of v0.6.0: statusline-command.sh,
hooks/show-usage-limits.sh, skills/usage/SKILL.md, and (added by this agent
2026-07-10, see [v060_capture_script_distribution_gap](v060_capture_script_distribution_gap.md))
scripts/capture-profile-session.sh. Then merges into settings.json:
- Existing settings.json: `cp` to `.bak`, then `jq` overwrites only `.statusLine` and
  `.hooks.SessionStart` keys wholesale (lines 46-68).
- No settings.json: `jq -n` writes both keys plus `$schema` from scratch (lines 71-89).

Non-idempotent by design: every run re-overwrites the same two keys regardless of
prior content. No deletion path — a key install.sh once wrote but no longer needs
is never cleaned up. No upgrade detection at all — same merge every time, no version
check, no diff of what already exists.

[?] SUPERSEDED 2026-07-10 — this "ZERO multi-profile awareness" claim was true
at 2026-07-06 map time but v0.5.0 (already shipped by 2026-07-06, tag exists)
added `CLAUDE_CONFIG_DIR` honoring to install.sh (`CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`,
install.sh:8) — README's own multi-account setup instructs
`CLAUDE_CONFIG_DIR=$HOME/.claude-personal ./install.sh` as the direct-install
path for a second profile. Remaining real gap: still no *deletion*/upgrade
path (unchanged, see above), and a second `./install.sh` run only works
correctly because each profile has its own settings.json — there's no
awareness of "I'm reinstalling into an already-provisioned second profile"
beyond that.

Darwin+Linux only (uname gate, lines 20-26); jq+curl required as deps.
