---
name: v060-capture-script-distribution-gap
description: v0.6.0 ship-gate finding — install.sh never shipped scripts/capture-profile-session.sh, so auto-capture never fired on a fresh install; fixed 2026-07-10
metadata:
  type: project
---

**Finding (ship-gate review, 2026-07-10, HEAD 7f71fbd on cf/v0.6.0-file-first-credentials):**
v0.6.0's headline feature is auto-capture ("`/login` is all you have to do,"
CHANGELOG.md v0.6.0 Added). `hooks/show-usage-limits.sh`'s `maybe_auto_capture()`
resolves the capture script via `resolve_capture_script()`:
`${_CREDS_DIR}/scripts/capture-profile-session.sh`, falling back to
`$HOME/.claude/scripts/capture-profile-session.sh`. Neither install.sh (curl-pipe
path) nor the README's manual-install `cp` block ever placed the script at
either of those locations — `scripts/` wasn't even in install.sh's directory
list. Confirmed by reading hooks/show-usage-limits.sh:207-220 alongside
install.sh's original download list (statusline-command.sh, hooks/show-usage-limits.sh,
skills/usage/SKILL.md only — no scripts/). The hook's own code comment
(show-usage-limits.sh:210-212, still present) explicitly says: "install.sh
does not currently ship scripts/capture-profile-session.sh, so this commonly
falls through to a path that doesn't exist." Degradation was graceful (loud
stderr skip, render proceeds) but silent to anyone not reading a live session's
stderr or `/tmp` artifacts — so auto-capture would never have fired for any
user on any documented install path, with zero surfaced warning at install
time or in Known Issues.

**Verdict:** treated as pre-ship blocking, not a Known Issues entry — the fix
was a mechanical 4-line addition matching install.sh's existing per-file
download pattern exactly, with zero design ambiguity, so shipping it broken
and documenting the gap would have been strictly worse than just fixing it.

**Fix applied 2026-07-10** (by this agent, this session):
- `install.sh`: added `mkdir -p "$CLAUDE_DIR/scripts"` alongside the other
  directory creates, and a download block for
  `scripts/capture-profile-session.sh` → `$CLAUDE_DIR/scripts/capture-profile-session.sh`
  + chmod +x, mirroring the existing statusline/hook download blocks exactly.
- Verified path match: install.sh's `CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`
  equals the hook's `_CREDS_DIR` for both work and personal profiles (both
  resolve off `CLAUDE_CONFIG_DIR`), so the new install path lines up exactly
  with `resolve_capture_script()`'s preferred path — no path-resolution
  mismatch once the file exists.
- `README.md`: added a fourth row to the "How it works" three-components
  table for `scripts/capture-profile-session.sh`; added the matching
  `mkdir`/`cp`/`chmod` lines to the manual-install code block (previously
  only copied statusline-command.sh + hooks/show-usage-limits.sh +
  skills/usage/SKILL.md — same gap as install.sh, just undocumented instead
  of unscripted).
- `CHANGELOG.md`: appended a clause to the existing (untagged, still-draft)
  v0.6.0 `scripts/capture-profile-session.sh` Added bullet noting install.sh
  now ships it on both paths. Edited in place rather than added as a new
  entry, since no `chore(release): v0.6.0` commit or tag exists yet — see
  [[release_workflow]] step ordering (CHANGELOG edits happen pre-tag).

**Cross-agent flag (NOT fixed by this agent — out of file scope):**
`hooks/show-usage-limits.sh:210-212`'s code comment ("install.sh does not
currently ship scripts/capture-profile-session.sh...") is now stale/false
post-fix. That file belongs to claudeline-core, not this agent's owned six
files — flag for claudeline-core to update or remove that comment on next
touch of the hook.

**Standing takeaway:** when a release adds a new script/hook that another
shipped file auto-invokes, always grep install.sh's download list AND
README's manual-install block for that new file's path — a script existing
in the repo and being referenced in docs/CHANGELOG is not evidence it's
actually distributed. Check this on every future release that adds a new
top-level script or hook, not just this one.
