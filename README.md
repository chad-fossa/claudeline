```
        __                __     ___
  _____/ /___ ___  ______/ /__  / (_)___  ___
 / ___/ / __ `/ / / / __  / _ \/ / / __ \/ _ \
/ /__/ / /_/ / /_/ / /_/ /  __/ / / / / /  __/
\___/_/\__,_/\__,_/\__,_/\___/_/_/_/ /_/\___/
```

**A rich statusline for Claude Code.**
Context window. Usage limits with reset times. Git integration.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)]()
[![Claude Code](https://img.shields.io/badge/Claude_Code-compatible-blueviolet.svg)]()

<!-- TODO: Replace with actual screenshot -->
<!-- ![claudeline](./screenshot.png) -->

---

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/chad-fossa/claudeline/main/install.sh | bash
```

Restart Claude Code. That's it.

## What you get

```
▕██▎  ▏ 28% 3pm:9% 02/15:3% │ my-project:feature/auth #42 ←↑
```

| Segment | What it shows |
|---------|--------------|
| `▕██▎  ▏ 28%` | Context window usage. Green < 50%, yellow 50-85%, red > 85%. |
| `3pm:9%` | 5-hour usage at 9%. Resets at 3pm local time. |
| `02/15:3%` | 7-day usage at 3%. Resets on Feb 15. |
| `my-project:feature/auth` | Repo and branch. |
| `⎇my-project:feature/auth` | Repo and branch inside a git worktree. |
| `#42` | PR number. Clickable in supported terminals. |
| `←↑` | Working tree and sync status (see reference below). |

## How it works

Three components, one cache file.

| File | Role |
|------|------|
| `statusline-command.sh` | Renders the statusline every prompt. Reads context from Claude's JSON input (uses pre-calculated `used_percentage` when available), usage from cache. |
| `hooks/show-usage-limits.sh` | Fetches usage from Anthropic's API at session start and after compaction. Writes to `/tmp/.claude_usage_limits.json`. |
| `skills/usage/SKILL.md` | Adds a `/usage` slash command to refresh on demand. |

Usage is fetched only when it matters -- not on every render. The hook writes, the statusline reads.

## Usage

Usage limits refresh automatically on:

- **Session start** via SessionStart hook
- **Context compaction** via the compact matcher
- **`/usage` command** for manual refresh anytime

## Symbol reference

| Symbol | Meaning |
|--------|---------|
| `←` | Unstaged changes |
| `→` | Staged, ready to commit |
| `↔` | Both staged and unstaged |
| `↑` | Commits to push |
| `↓` | Commits to pull |
| `⇅` | Both push and pull |
| `⎇` | Inside a git worktree |

## Requirements

- **macOS** (uses Keychain for OAuth token retrieval)
- **Claude Code** with OAuth login
- **jq**
- **gh** (optional, for PR detection)

## Manual installation

If you prefer not to pipe to bash:

```bash
git clone https://github.com/chad-fossa/claudeline.git
cd claudeline

cp statusline-command.sh ~/.claude/
mkdir -p ~/.claude/hooks ~/.claude/skills/usage
cp hooks/show-usage-limits.sh ~/.claude/hooks/
cp skills/usage/SKILL.md ~/.claude/skills/usage/

chmod +x ~/.claude/statusline-command.sh ~/.claude/hooks/show-usage-limits.sh
```

Then merge `settings-example.json` into your `~/.claude/settings.json`.

## Credits

Inspired by [Claude Code Usage Limits Statusline](https://codelynx.dev/posts/claude-code-usage-limits-statusline) by CodeLynx.

## License

MIT
