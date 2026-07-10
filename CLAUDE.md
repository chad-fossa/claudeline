# claudeline — contributor notes

A bash statusline for Claude Code. Runs as `statusLine.command` per session. Usage limits arrive on the statusline's own stdin (`rate_limits.five_hour`/`.seven_day`, sent by Claude Code ≥2.1.80) — no fetch, no hook, no credentials. `statusline-command.sh` renders it and writes a per-account cache at `/tmp/claudeline-<uid>/.claude_usage_limits_{account}.json` so a render that arrives before the session's first API response still has something to show.

## Versioning

This project follows [Semantic Versioning](https://semver.org):

- **MAJOR** — incompatible changes to the install layout, settings schema, statusline input/output contract, or required Claude Code version
- **MINOR** — new statusline segments, new env-var knobs, new skills, new account modes
- **PATCH** — bug fixes, doc tweaks, performance work, no behavioral surface change

Pre-1.0, a removal (deleted files, a changed install layout) can still ship as MINOR rather than MAJOR — but only with a loud, explicit callout in the CHANGELOG (see v0.7.0's `### Breaking` section for the pattern). Don't bury a removal in prose; a reader skimming section headers should be able to find it.

Each release is a `vMAJOR.MINOR.PATCH` git tag on the commit that bumps `CHANGELOG.md`.

## Release workflow

When shipping a release:

1. **Edit `CHANGELOG.md`**: add a new section at the top under the "Each release corresponds to..." line, dated `(YYYY-MM-DD)`, grouped by `### Features` / `### Fixes` / `### Docs` / `### Known issues`. Reference upstream issues by URL when relevant.
2. **Commit** with subject `chore(release): vX.Y.Z` and the changelog excerpt in the body.
3. **Tag** the release commit: `git tag -a vX.Y.Z -m "vX.Y.Z"`.
4. **Push** both the commit and the tag: `git push origin main && git push origin vX.Y.Z`.
5. **GitHub release** (optional): `gh release create vX.Y.Z --notes-file <(awk '/^## v/{n++} n==1' CHANGELOG.md)` to publish the latest section as the release notes.

Don't squash unrelated work into a release commit — it should only touch `CHANGELOG.md` (and `README.md` if user-facing copy needs updating).

## What goes in `### Fixes`

Lead with the user-visible symptom, then explain the root cause briefly. Future-readers searching the changelog for "my statusline shows X" should find the entry.

Good: *"Hook keychain lookup: Symptom: usage stats missing on personal account, fine on work. Anchors the grep on `claudeAiOauth.accessToken` so MCP tokens can't shadow it."*

Bad: *"Refactor get_token logic"* — gives the reader nothing to match against.

## Backfilling tags

If a previous release was documented in CHANGELOG but never tagged, backfill with the original release date:

```bash
git tag -a vX.Y.Z <commit-sha> -m "vX.Y.Z (backfilled)"
git push origin vX.Y.Z
```

Use the commit that matches the changelog content, not the latest commit.

## Testing changes

Usage limits arrive on stdin — there's no fetch to stub, no credentials, no network call. Feed `statusline-command.sh` a JSON payload with `rate_limits` set to exercise it:

```bash
echo '{"workspace":{"current_dir":"."},"context_window":{"used_percentage":5},"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1783699800},"seven_day":{"used_percentage":16,"resets_at":1783850400}}}' | bash statusline-command.sh

# Inspect the cache it writes for a render that arrives before rate_limits does
cat /tmp/claudeline-<uid>/.claude_usage_limits_work.json
```

The cache file is what a `rate_limits`-less render falls back to — if it doesn't exist, or its schema is unrecognized (an old pre-v0.7.0 cache), the `5h:X% 7d:X%` segment won't render (never a fabricated `0%`).

`scripts/test.sh` is this repo's smoke-test harness — no CI runs it, so run it manually before landing changes:

```bash
bash scripts/test.sh
```

`detect_account()` and `verify_runtime_dir()` are the sole copy in `statusline-command.sh` — there's no hook or capture script left to keep them in sync with.

PR detection still shells out to `gh` when stdin doesn't carry `.pr` — that path is tested with a PATH-shimmed `gh` stub under the isolated `$HOME`, asserting it's invoked (or not) depending on whether the test payload carries `.pr`.

## Known upstream constraints

- `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` env vars override OAuth and force inference-only mode; usage limits don't apply in that mode, so `rate_limits` won't appear on stdin. Don't export either globally if you want the usage segment.

## Experts

- consult-expert: claudeline-distribution — install.sh, settings-example.json, README.md, CHANGELOG.md, CLAUDE.md, LICENSE: fresh-install layout and release/versioning discipline.
- consult-expert: claudeline-core — statusline-command.sh, skills/usage/: statusline render cycle, stdin usage contract, cache contract, account detection.
  `<!-- cf:orientation -->` marker onward) to the consuming repo's ROOT CLAUDE.md in SHARED
  mode only. It intentionally makes NO mention of change-factory — the committed experts load
  as ordinary Claude Code subagents, so the orientation must read correctly for any teammate
  whether or not they have the plugin installed. The `<!-- cf:orientation -->` marker is the
  stable anchor the Doctor heal uses to locate + update this section on a future upgrade.
  In LOCAL mode nothing is appended — the repo stays untouched.
-->

<!-- cf:orientation -->
## Domain experts

This repo ships domain experts in `.claude/agents/` — specialist subagents, each owning a
specific area of the codebase. They load as ordinary Claude Code subagents. Consult the
relevant expert when you work in its area.

