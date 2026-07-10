```
        __                __     ___
  _____/ /___ ___  ______/ /__  / (_)___  ___
 / ___/ / __ `/ / / / __  / _ \/ / / __ \/ _ \
/ /__/ / /_/ / /_/ / /_/ /  __/ / / / / /  __/
\___/_/\__,_/\__,_/\__,_/\___/_/_/_/ /_/\___/
```

**A rich statusline for Claude Code.**
Context window. Usage limits with reset times. Git integration. Multi-account support.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg)]()
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
[W] ▕██▎  ▏ 28% 3pm:9% 02/15:3% │ my-project:feature/auth #42 ←↑
```

| Segment | What it shows |
|---------|--------------|
| `[W]` | Account indicator. Only shown when multiple accounts exist. |
| `▕██▎  ▏ 28%` | Context window usage. Green < 50%, yellow 50-85%, red > 85%. |
| `3pm:9%` | 5-hour usage at 9%. Resets at 3pm local time. |
| `02/15:3%` | 7-day usage at 3%. Resets on Feb 15. |
| `my-project:feature/auth` | Repo and branch. |
| `⎇my-project:feature/auth` | Repo and branch inside a git worktree. |
| `#42` | PR number. Clickable in supported terminals. |
| `←↑` | Working tree and sync status (see reference below). |

## How it works

Two components. No fetching, no credentials.

| File | Role |
|------|------|
| `statusline-command.sh` | Renders the statusline every prompt. Reads context and usage straight off Claude Code's own JSON input (`context_window`, `rate_limits`) and caches usage per account so it still renders on a render that arrives before the session's first API response. |
| `skills/usage/SKILL.md` | Explains where usage comes from if you ask `/usage` — there's nothing to trigger, usage just arrives. |

Claude Code hands each session its own usage limits on the statusline's stdin (`rate_limits.five_hour`/`.seven_day`) — no separate API call, no OAuth token, no shared credential state between profiles.

## Usage

Usage limits arrive automatically on every render, as part of the same JSON input Claude Code already sends the statusline. There are two reasons the segment can be blank:

- **Temporary:** a brand-new session has no `rate_limits` yet. It stays blank until your first prompt gets its first API response, then shows up on the next render and stays current from there.
- **Permanent:** on some Claude.ai Max/OAuth configurations, `rate_limits` never arrives at all — see [anthropics/claude-code#40094](https://github.com/anthropics/claude-code/issues/40094) and [#45133](https://github.com/anthropics/claude-code/issues/45133) — and it's also expected on non-Pro/Max plans. There's no fallback for this case: claudeline no longer fetches usage on its own (the old fetch path was the cross-profile leak fixed in v0.7.0), so if the segment is still blank after a few prompts, the fix has to come from Claude Code upstream, not from claudeline.

## Multiple accounts

claudeline supports running separate work and personal Claude Code accounts on the same machine. Each session only ever sees its own usage — since usage arrives per-session on stdin, not via a shared credential, cross-profile leakage is structurally impossible: there's no shared token for one profile's login to silently overwrite another's.

### Setup

1. Add aliases to your `.zshrc`:

```bash
alias claude-work="CLAUDE_CONFIG_DIR=$HOME/.claude claude"
alias claude-personal="CLAUDE_CONFIG_DIR=$HOME/.claude-personal claude"
```

2. Run `claude-personal` and authenticate with your personal account.

3. Either symlink shared config from work to personal:

```bash
shared=(CLAUDE.md settings.json skills statusline-command.sh hooks plugins
        agents commands scripts projects history-index.sqlite statusline-ink
        plans statsig)

for item in "${shared[@]}"; do
  rm -rf ~/.claude-personal/"$item"
  ln -sf ~/.claude/"$item" ~/.claude-personal/"$item"
done
```

   ...or install claudeline directly into the personal profile instead:

```bash
CLAUDE_CONFIG_DIR=$HOME/.claude-personal ./install.sh
```

### How it works

- The statusline shows `[W]` or `[P]` when both `~/.claude` and `~/.claude-personal` exist.
- Each session's usage comes only from that session's own stdin — there's no credential file or Keychain entry to fetch from, so there's nothing for one profile's login to overwrite in another's.
- `claude` (no alias) uses `~/.claude` by default — your work account.

### Cross-profile identity marker

| Marker | Meaning |
|--------|---------|
| Dim `=` after the account label (e.g. `[P]=`) | Both profiles are logged into the *same* account (read directly from each profile's `.claude.json`). Informational only — it no longer implies anything about which usage numbers you're seeing, since each bar always renders its own session's own stdin. |
| Account label itself dimmed (e.g. `[W]`) | The account was assumed (`CLAUDE_CONFIG_DIR` unset) rather than explicitly detected. |

### Customizing account labels

Set env vars in `.zshrc`:

```bash
export CLAUDE_ACCOUNT_WORK_LABEL="W"           # default: "W"
export CLAUDE_ACCOUNT_PERSONAL_LABEL="P"        # default: "P"
export CLAUDE_ACCOUNT_WORK_COLOR=$'\033[36m'    # cyan (default)
export CLAUDE_ACCOUNT_PERSONAL_COLOR=$'\033[35m' # magenta (default)
```

### What's shared vs separate

| Shared | Per-Account |
|--------|-------------|
| CLAUDE.md, settings.json | settings.local.json |
| Skills, plugins, hooks | Usage limit cache (from that session's own stdin) |
| Statusline config | Session env/cache |
| Conversation history | |
| Project memory | |

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

- **macOS or Linux**
- **Claude Code ≥2.1.80** — the version that started sending `rate_limits` on the statusline's stdin
- **A Claude.ai Pro or Max plan** — usage limits (and so `rate_limits`) don't apply on API-key/other billing
- **jq**
- **gh** (optional, for PR detection when stdin doesn't carry `.pr`)

See [Usage](#usage) above if the usage segment stays blank — a brand-new session and an upstream gap look the same on screen but resolve differently.

## Manual installation

If you prefer not to pipe to bash:

```bash
git clone https://github.com/chad-fossa/claudeline.git
cd claudeline

cp statusline-command.sh ~/.claude/
mkdir -p ~/.claude/skills/usage
cp skills/usage/SKILL.md ~/.claude/skills/usage/

chmod +x ~/.claude/statusline-command.sh
```

Then merge `settings-example.json` into your `~/.claude/settings.json`.

## Credits

Inspired by [Claude Code Usage Limits Statusline](https://codelynx.dev/posts/claude-code-usage-limits-statusline) by CodeLynx.

## License

MIT
