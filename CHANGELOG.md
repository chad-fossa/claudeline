# Changelog

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
