# claudeline — contributor notes

A bash statusline for Claude Code. Runs as `statusLine.command` per session, plus a `SessionStart` hook (`hooks/show-usage-limits.sh`) that fetches usage limits via the Anthropic OAuth API and caches them at `/tmp/claudeline-<uid>/.claude_usage_limits_{account}.json`.

## Versioning

This project follows [Semantic Versioning](https://semver.org):

- **MAJOR** — incompatible changes to the install layout, settings schema, hook output contract, or required Claude Code version
- **MINOR** — new statusline segments, new env-var knobs, new hooks/skills, new account modes
- **PATCH** — bug fixes, doc tweaks, performance work, no behavioral surface change

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

The hook depends on macOS Keychain access (`security find-generic-password -s "Claude Code-credentials"`) and a network call to `api.anthropic.com/api/oauth/usage`. To test locally without restarting Claude Code:

```bash
# Work account (CLAUDE_CONFIG_DIR unset or = ~/.claude)
bash hooks/show-usage-limits.sh

# Personal account
CLAUDE_CONFIG_DIR=$HOME/.claude-personal bash hooks/show-usage-limits.sh

# Inspect the cache
cat /tmp/claudeline-<uid>/.claude_usage_limits_work.json
cat /tmp/claudeline-<uid>/.claude_usage_limits_personal.json
```

The cache file is what the statusline reads — if it doesn't exist or is stale, the `5h:X% 7d:X%` segment won't render.

`scripts/test.sh` is this repo's smoke-test harness — no CI runs it, so run it manually before landing changes:

```bash
bash scripts/test.sh
```

It asserts the load-bearing invariant that `detect_account()` is duplicated verbatim across `statusline-command.sh`, `hooks/show-usage-limits.sh`, and `scripts/capture-profile-session.sh` (all three install/run independently, so no shared lib) — all three copies must stay identical.

The hook's file-first credentials and owned OAuth refresh (v0.6.0) are tested with PATH-shimmed `curl` and `security` stubs under the isolated `$HOME` — a `curl` stub keyed on URL (`/v1/oauth/token` vs `/api/oauth/usage`) returns configurable bodies/HTTP codes via env vars (`OAUTH_HTTP_CODE`, `OAUTH_RESPONSE_BODY`, `USAGE_RESPONSE_BODY`), and a `security` stub with a sentinel file lets tests assert Keychain was (or wasn't) invoked. Fake tokens only (`tok_fake_*`) — never real-looking token shapes, even in test fixtures.

Identity verification and auto-capture (also v0.6.0) extend the same pattern:
- The capture script's identity probe (`/api/oauth/profile`) gets its own `curl` stub keyed on `PROFILE_HTTP_CODE`/`PROFILE_RESPONSE_BODY`, separate from the refresh stub above since both can be in play in the same test file.
- Auto-capture's corroboration window reads the Keychain item's modification time WITHOUT `-w` (metadata only, never the secret) — its `security` stub branches on whether `-w` is present and, when absent, prints a fake `attributes:` block with an `"mdat"<timestamp>="YYYYMMDDHHMMSSZ"` line the hook parses. Tests compute that timestamp from real epoch offsets (`epoch_to_mdat_ts()`) around the current time rather than hardcoding a date, so the corroboration-window math stays correct regardless of when the suite runs.

## Known upstream constraints

- macOS Keychain stores only one Claude Max OAuth token (`Claude Code-credentials`); `/login` on a second account overwrites the first. Tracked at [anthropics/claude-code#20553](https://github.com/anthropics/claude-code/issues/20553). Work around by re-`/login`-ing on switch.
- `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` env vars override OAuth and force inference-only mode. The hook will still read the keychain, but the active session itself loses Remote Control. Don't export either globally.

## Experts

- consult-expert: claudeline-distribution — install.sh, settings-example.json, README.md, CHANGELOG.md, CLAUDE.md, LICENSE: fresh-install layout and release/versioning discipline.
- consult-expert: claudeline-core — statusline-command.sh, hooks/, skills/usage/: statusline render+refresh cycle, cache contract, account detection, OAuth acquisition.
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

