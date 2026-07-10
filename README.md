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

Three components, one cache file per account.

| File | Role |
|------|------|
| `statusline-command.sh` | Renders the statusline every prompt. Reads context from Claude's JSON input (uses pre-calculated `used_percentage` when available), usage from cache. |
| `hooks/show-usage-limits.sh` | Fetches usage from Anthropic's API at session start and after compaction. Writes to `/tmp/claudeline-<uid>/.claude_usage_limits_<account>.json` (per-user 0700 dir). |
| `skills/usage/SKILL.md` | Adds a `/usage` slash command to refresh on demand. |
| `scripts/capture-profile-session.sh` | Copies the Keychain session into this profile's own credentials file, identity-verified. Auto-invoked by the hook after `/login` (macOS) — see [Per-profile credentials](#per-profile-credentials-macos). |

Usage is fetched only when it matters -- not on every render. The hook writes, the statusline reads.

## Usage

Usage limits refresh automatically on:

- **Session start** via SessionStart hook
- **Context compaction** via the compact matcher
- **`/usage` command** for manual refresh anytime

All refreshes apply to the active account — if you're in a personal session, `/usage` updates the personal cache; work session updates the work cache.

## Multiple accounts

claudeline supports running separate work and personal Claude Code accounts on the same machine. Each gets its own auth credentials and usage cache while sharing config.

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

- **`/login` in either profile is all you have to do.** claudeline notices the fresh login and captures + verifies that profile's own session automatically — see [Per-profile credentials (macOS)](#per-profile-credentials-macos).
- Credentials are stored per-account: `$CLAUDE_CONFIG_DIR/.credentials.json` on Linux, or via auto-capture (or [manual capture](#manual-capture-troubleshooting--recovery)) on macOS; otherwise macOS falls back to the shared Keychain entry
- The statusline shows `[W]` or `[P]` when both `~/.claude` and `~/.claude-personal` exist
- Usage limits are cached per-account so they don't clobber each other
- `claude` (no alias) uses `~/.claude` by default — your work account
- macOS Keychain has only one slot for the Claude Max OAuth token, so both profiles can end up silently sharing the same login — see [Cross-profile identity markers](#cross-profile-identity-markers) and [anthropics/claude-code#20553](https://github.com/anthropics/claude-code/issues/20553) (still open upstream, unfixed)

### Per-profile credentials (macOS)

macOS Keychain has only one slot for the Claude Max OAuth token (`Claude Code-credentials`), so both profiles' statuslines would otherwise end up reading the same last-login session — see [Cross-profile identity markers](#cross-profile-identity-markers) below. claudeline fixes this instead of just flagging it: **`/login` in either profile — claudeline picks it up automatically within one refresh** (session start, `/usage`, or the next background statusline refresh).

Here's what happens behind the scenes: `hooks/show-usage-limits.sh` notices this profile's `.claude.json` got a fresh login (its `oauthAccount.profileFetchedAt` changed) and hands off to `scripts/capture-profile-session.sh`, which copies the Keychain session into that profile's own `$CLAUDE_CONFIG_DIR/.credentials.json` — but only after verifying with Anthropic's account-profile endpoint that the token it's about to capture actually belongs to this profile's account. A verified capture is stamped `claudeline.verified_account_uuid`; from then on the hook reads that file first and refreshes it itself when the token expires, so logins become rare — claudeline owns the OAuth refresh for that file rather than relying on Keychain.

A capture only proceeds when the login and the Keychain write happen close together (within 30s by default, `CLAUDELINE_CAPTURE_WINDOW_SECS` to adjust); outside that window claudeline vetoes the capture rather than risk grabbing the wrong profile's fresh login, and drops `/tmp/claudeline-<uid>/.claude_cred_capture_vetoed_<account>`. The identity probe can also veto a capture outright if the token turns out to belong to a different account than expected — same artifact, no file written either way.

If claudeline's owned refresh ever fails (upstream token/grant shape changes, network issues), it never falls back to the shared Keychain slot silently — it renders a `!` marker instead (see the table below) and drops a loud artifact at `/tmp/claudeline-<uid>/.claude_cred_refresh_failed_<account>`.

### Manual capture (troubleshooting / recovery)

Auto-capture's trigger depends on `.claude.json`'s `oauthAccount.profileFetchedAt`, which older Claude Code builds don't write — on those, a login never fires auto-capture. Run the capture script directly to force one (also useful to force a re-verification, or if a veto artifact shows up and you want to retry once the timing settles):

```bash
CLAUDE_CONFIG_DIR=$HOME/.claude-personal scripts/capture-profile-session.sh
```

This runs the same identity-verified capture auto-capture uses, synchronously, with output on stdout (never prints the token itself). It shares the same credential lock as `refresh_token_grant` and auto-capture, so if one of those is mid-refresh/capture for this account, the manual run exits 1 with a message instead of racing it — just try again in a moment.

### Cross-profile identity markers

claudeline can't fully close the shared-keychain-slot issue above on its own, but it detects mismatches and flags them instead of silently showing the wrong numbers:

| Marker | Meaning |
|--------|---------|
| Dim `=` after the account label (e.g. `[P]=`) | Both profiles are logged into the *same* account. |
| Dim `?` after the usage segment (macOS only) | This profile's credentials aren't a VERIFIED per-profile capture (no file, an unverified capture, or a verified-uuid mismatch) — the usage numbers shown may belong to the wrong profile, treat them as unverified. Retires only after one verified capture: `/login` for this profile while online (needs a Claude Code build that writes `profileFetchedAt`, or run [manual capture](#manual-capture-troubleshooting--recovery) directly). Provenance is computed once when the usage cache is written (session start / `/usage` / background refresh, at most every 300s), not on every render, so a just-completed verified capture can lag up to that TTL before `?` clears. |
| Dim/red `!` after the usage segment | This profile's `.credentials.json` exists but claudeline's owned refresh failed — numbers are stale and the token could not be renewed. Check `/tmp/claudeline-<uid>/.claude_cred_refresh_failed_<account>`. |
| Account label itself dimmed (e.g. `[W]`) | The account was assumed (`CLAUDE_CONFIG_DIR` unset) rather than explicitly detected. |

A capture that gets vetoed (identity mismatch, or login/Keychain timing outside the corroboration window) never writes a file — it drops `/tmp/claudeline-<uid>/.claude_cred_capture_vetoed_<account>` instead, and `?` stays exactly as before the login attempt.

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
| CLAUDE.md, settings.json | Auth credentials (per-account file, auto-captured on macOS) |
| Skills, plugins, hooks | settings.local.json |
| Statusline config | Usage limit cache |
| Conversation history | Session env/cache |
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
  - Both read the OAuth token from `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`) first, refreshing it in place when it expires
  - macOS falls back to Keychain (`Claude Code-credentials`) only when that file is absent — auto-capture (see [Per-profile credentials](#per-profile-credentials-macos)) keeps it populated after `/login`
- **Claude Code** with OAuth login
- **jq**
- **gh** (optional, for PR detection)

## Manual installation

If you prefer not to pipe to bash:

```bash
git clone https://github.com/chad-fossa/claudeline.git
cd claudeline

cp statusline-command.sh ~/.claude/
mkdir -p ~/.claude/hooks ~/.claude/skills/usage ~/.claude/scripts
cp hooks/show-usage-limits.sh ~/.claude/hooks/
cp skills/usage/SKILL.md ~/.claude/skills/usage/
cp scripts/capture-profile-session.sh ~/.claude/scripts/

chmod +x ~/.claude/statusline-command.sh ~/.claude/hooks/show-usage-limits.sh ~/.claude/scripts/capture-profile-session.sh
```

Then merge `settings-example.json` into your `~/.claude/settings.json`.

## Credits

Inspired by [Claude Code Usage Limits Statusline](https://codelynx.dev/posts/claude-code-usage-limits-statusline) by CodeLynx.

## License

MIT
