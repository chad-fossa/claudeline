---
name: changelog-symptom-first
description: CLAUDE.md's rule for what goes in ### Fixes — lead with symptom, not implementation
metadata:
  type: feedback
---

CLAUDE.md convention (confirmed 2026-07-06): `### Fixes` entries must lead with
the user-visible symptom, then the root cause — so a future reader searching
"my statusline shows X" finds the entry.

Good example (from CLAUDE.md, matches actual v0.3.1 changelog entry): "Hook
keychain lookup: Symptom: usage stats missing on personal account, fine on
work. Anchors the grep on `claudeAiOauth.accessToken`..."

Bad example (explicitly called out): "Refactor get_token logic" — no symptom
to match against.

**Why:** future-reader-searchability, stated directly in CLAUDE.md.
**How to apply:** flag any Fixes entry that opens with an implementation verb
(refactor/replace/switch) instead of a symptom description — check this first
on every release-shaped question, before semver category or anything else.

Checked v0.2.0–v0.4.0 entries in CHANGELOG.md: all currently comply.
