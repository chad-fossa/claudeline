# Changelog

All notable changes to this project follow [Semantic Versioning](https://semver.org).
Each release corresponds to a `vMAJOR.MINOR.PATCH` git tag.

## v0.3.1 (2026-05-10)

### Fixes
- **Hook keychain lookup**: Read the Claude Max OAuth token from the default `Claude Code-credentials` keychain entry instead of trying to find a hashed `Claude Code-credentials-{hash}` entry per `CLAUDE_CONFIG_DIR`. The hashed entry exists but only holds `mcpOAuth` tokens with empty `accessToken` fields — the previous logic matched an empty MCP token and emitted "Could not get credentials". Symptom: usage stats missing on the personal account, fine on work. Anchors the grep on `claudeAiOauth.accessToken` so MCP tokens can't shadow it.
- **/usage skill**: Pipe empty JSON to the hook when invoked manually so it doesn't hang on stdin. Update description to reflect per-account cache paths.

### Docs
- Clarify in the `/usage` skill that it refreshes whichever account is currently active.

### Known issues
- macOS Keychain still has only one slot for the Claude Max OAuth token (`Claude Code-credentials`), so switching accounts via `/login` overwrites the previous account's token. This is upstream — see [anthropics/claude-code#20553](https://github.com/anthropics/claude-code/issues/20553).

## v0.3.0 (2026-03-13)

### Features
- **Multi-account support**: Run separate work and personal Claude Code accounts on the same machine with per-account usage caching and `[W]`/`[P]` indicators
- **Customizable account labels**: Set `CLAUDE_ACCOUNT_WORK_LABEL`, `CLAUDE_ACCOUNT_PERSONAL_LABEL`, and color env vars in `.zshrc`

### Fixes
- **Token extraction**: Switch from `jq` to `grep` for extracting OAuth tokens from Keychain — fixes breakage when MCP OAuth tokens bloat the credentials JSON beyond Keychain's output limit
- **PR rate limiting**: Add lock guard to prevent concurrent `gh pr view` calls from piling on during rapid statusline renders. Increase PR cache TTL from 120s to 600s.
- **Usage cache mismatch**: Default to "work" account when `transcript_path` isn't available, instead of looking for a non-existent "default" cache file

## v0.2.0 (2026-03-10)

### Features
- **Worktree detection**: Show `⎇worktree-name` prefix when working in a git worktree instead of the repo name
- **Context window**: Use pre-calculated `used_percentage` from Claude Code JSON input when available, with manual token calculation as fallback

### Fixes
- **Usage limits time format**: Show 12h AM/PM (e.g., `3pm`) instead of 24h format for 5-hour reset time
- **Timezone parsing**: Strip both fractional seconds and timezone suffix from reset timestamps for reliable parsing

## v0.1.0 (2025-01-10)

- Initial release
