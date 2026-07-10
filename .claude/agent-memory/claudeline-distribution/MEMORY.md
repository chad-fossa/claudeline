# claudeline-distribution memory

- [install.sh merge semantics](install_sh_merge_semantics.md) — jq overwrite of statusLine/hooks.SessionStart, .bak, non-idempotent, no upgrade path; profile-awareness note [?] superseded 2026-07-10 (v0.5.0 already added CLAUDE_CONFIG_DIR honoring)
- [settings-example.json hardcoded paths](settings_example_hardcoded_paths.md) — hardcodes ~/.claude, no CLAUDE_CONFIG_DIR variant
- [Release workflow](release_workflow.md) — semver rules, changelog→commit→tag→push steps, tag-backfill procedure; v0.4.0 unpushed-tag thread [?] likely resolved as of 2026-07-10
- [v0.6.0 capture-script distribution gap](v060_capture_script_distribution_gap.md) — install.sh never shipped scripts/capture-profile-session.sh (auto-capture's headline feature never fired); fixed pre-ship 2026-07-10 in install.sh + README + CHANGELOG
- [Changelog symptom-first rule](changelog_symptom_first.md) — Fixes entries must lead with user-visible symptom, not implementation verb
- [Deployed drift is bidirectional](deployed_drift_bidirectional.md) — deployed ~/.claude files can be ahead or behind this repo; check both directions
- [Multi-profile standing checklist](multi_profile_checklist.md) — install.sh/settings-example.json must track core's CLAUDE_CONFIG_DIR isolation model; check on every core isolation change
