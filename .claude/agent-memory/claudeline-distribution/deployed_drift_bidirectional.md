---
name: deployed-drift-bidirectional
description: A deployed ~/.claude install can be ahead OR behind this repo — check both directions
metadata:
  type: project
---

Per domain-bootstrap.json researcher summary (2026-07-06, not independently
re-verified this session — deployed files live outside this repo's tree):

- statusline-command.sh deployed at `~/.claude` was AHEAD of the repo: already
  keyed the PR cache by `_${ACCOUNT_ID}`, something the repo's checked-in
  version didn't yet do.
- The deployed hook (`hooks/show-usage-limits.sh`) was BEHIND: macOS-only,
  predating this repo's Linux support (shipped in v0.4.0 per CHANGELOG.md).

**Why:** install.sh has no upgrade/reconciliation path (see
[[install_sh_merge_semantics]]) — a fresh install always overwrites with
repo HEAD, but nothing ever re-syncs an existing deployed copy, so drift can
accumulate in either direction depending on when each file was last touched
locally vs. in-repo.

**How to apply:** never assume "the repo is the source of truth, deployed is
stale" — check both. When investigating a claudeline behavior discrepancy,
diff the actual `~/.claude` files against the repo before attributing it to
one side.
