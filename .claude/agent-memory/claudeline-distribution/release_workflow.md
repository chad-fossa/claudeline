---
name: release-workflow
description: claudeline semver rules, release steps, and tag-backfill procedure from CLAUDE.md
metadata:
  type: reference
---

Confirmed against CLAUDE.md 2026-07-06.

**Semver categories:**
- MAJOR — incompatible changes to install layout, settings schema, hook output
  contract, or required Claude Code version.
- MINOR — new statusline segments, new env-var knobs, new hooks/skills, new
  account modes.
- PATCH — bug fixes, doc tweaks, performance work, no behavioral surface change.

**Release steps:**
1. Edit CHANGELOG.md: new dated section (`YYYY-MM-DD`) at top, grouped
   `### Features` / `### Fixes` / `### Docs` / `### Known issues`.
2. Commit `chore(release): vX.Y.Z` (changelog excerpt in body). Should touch
   only CHANGELOG.md (+ README.md if user-facing copy changed) — don't bundle
   unrelated work.
3. Tag: `git tag -a vX.Y.Z -m "vX.Y.Z"` on the release commit.
4. Push commit + tag: `git push origin main && git push origin vX.Y.Z`.
5. Optional: `gh release create vX.Y.Z --notes-file <(awk '/^## v/{n++} n==1' CHANGELOG.md)`.

**Backfilling tags:** `git tag -a vX.Y.Z <commit-sha> -m "vX.Y.Z (backfilled)"` —
must target the commit matching the changelog content, not latest HEAD.

At map time (2026-07-06 per domain-bootstrap.json), open thread: 0d6ae13 +
v0.4.0 tag were unpushed, and a `feat/linux-support` branch was superseded but
not cleaned up. Worth re-checking current repo state before assuming these are
resolved — they were noted by the researcher pass, not independently verified here.
