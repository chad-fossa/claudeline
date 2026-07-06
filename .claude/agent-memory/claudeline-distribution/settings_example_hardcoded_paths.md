---
name: settings-example-hardcoded-paths
description: settings-example.json hardcodes ~/.claude, no profile parameterization
metadata:
  type: reference
---

settings-example.json (confirmed 2026-07-06) hardcodes `~/.claude` in both the
statusLine command (`bash ~/.claude/statusline-command.sh`) and both SessionStart
hook commands (`~/.claude/hooks/show-usage-limits.sh`). Targets manual-install
users who merge by hand instead of piping install.sh to bash.

Same gap as install.sh: no `CLAUDE_CONFIG_DIR`-relative form, no per-profile
variant shown. See [[multi_profile_checklist]] — every core isolation change
should prompt a check of whether this file (and install.sh) need to reflect it.
