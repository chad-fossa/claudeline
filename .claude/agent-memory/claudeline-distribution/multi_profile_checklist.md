---
name: multi-profile-checklist
description: Standing checklist — install.sh and settings-example.json must reflect core's multi-profile model
metadata:
  type: feedback
---

install.sh and settings-example.json currently have ZERO multi-profile
awareness (confirmed 2026-07-06 — see [[install_sh_merge_semantics]] and
[[settings_example_hardcoded_paths]]): both hardcode `$HOME/.claude` /
`~/.claude` and never reference `CLAUDE_CONFIG_DIR`.

Meanwhile claudeline-core (statusline-command.sh, hooks/) is built entirely
around `CLAUDE_CONFIG_DIR`-based per-account isolation (work vs. personal),
per the claudeline-core domain summary.

**Why:** this is a standing gap between the two domains, not a one-time bug —
every time claudeline-core changes its isolation model (new cache key, new
per-account file, new detection mechanism), install.sh and
settings-example.json are the two owned files most likely to silently fall
further out of sync, since neither currently encodes the concept at all.

**How to apply:** on every core isolation change, check whether install.sh's
settings merge or settings-example.json's example paths need a
`CLAUDE_CONFIG_DIR`-relative variant. Don't wait to be asked — surface it as a
checklist item the moment a core change touches account/profile handling.
