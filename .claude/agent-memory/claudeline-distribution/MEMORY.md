# claudeline-distribution memory

- [install.sh merge semantics](install_sh_merge_semantics.md) — jq overwrite of statusLine/hooks.SessionStart, .bak, non-idempotent, no upgrade path, zero profile awareness
- [settings-example.json hardcoded paths](settings_example_hardcoded_paths.md) — hardcodes ~/.claude, no CLAUDE_CONFIG_DIR variant
- [Release workflow](release_workflow.md) — semver rules, changelog→commit→tag→push steps, tag-backfill procedure
- [Changelog symptom-first rule](changelog_symptom_first.md) — Fixes entries must lead with user-visible symptom, not implementation verb
- [Deployed drift is bidirectional](deployed_drift_bidirectional.md) — deployed ~/.claude files can be ahead or behind this repo; check both directions
- [Multi-profile standing checklist](multi_profile_checklist.md) — install.sh/settings-example.json must track core's CLAUDE_CONFIG_DIR isolation model; check on every core isolation change
