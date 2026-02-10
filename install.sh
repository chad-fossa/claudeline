#!/bin/bash
# claudeline installer
# Usage: curl -fsSL https://raw.githubusercontent.com/chadfurman/claudeline/main/install.sh | bash

set -e

REPO="https://raw.githubusercontent.com/chadfurman/claudeline/main"
CLAUDE_DIR="$HOME/.claude"

echo "Installing claudeline..."

# Check dependencies
for cmd in jq curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required. Install it first." >&2
    exit 1
  fi
done

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Error: claudeline requires macOS (uses Keychain for OAuth tokens)." >&2
  exit 1
fi

# Create directories
mkdir -p "$CLAUDE_DIR/hooks"
mkdir -p "$CLAUDE_DIR/skills/usage"

# Download files
echo "  Downloading statusline-command.sh..."
curl -fsSL "$REPO/statusline-command.sh" -o "$CLAUDE_DIR/statusline-command.sh"
chmod +x "$CLAUDE_DIR/statusline-command.sh"

echo "  Downloading show-usage-limits.sh..."
curl -fsSL "$REPO/hooks/show-usage-limits.sh" -o "$CLAUDE_DIR/hooks/show-usage-limits.sh"
chmod +x "$CLAUDE_DIR/hooks/show-usage-limits.sh"

echo "  Downloading usage skill..."
curl -fsSL "$REPO/skills/usage/SKILL.md" -o "$CLAUDE_DIR/skills/usage/SKILL.md"

# Merge into settings.json
SETTINGS="$CLAUDE_DIR/settings.json"
if [[ -f "$SETTINGS" ]]; then
  # Backup existing settings
  cp "$SETTINGS" "$SETTINGS.bak"
  echo "  Backed up existing settings to settings.json.bak"

  # Merge statusLine and hooks into existing settings
  MERGED=$(jq '
    .statusLine = {
      "type": "command",
      "command": ("bash " + env.HOME + "/.claude/statusline-command.sh")
    } |
    .hooks.SessionStart = [
      {
        "matcher": "startup",
        "hooks": [{"type": "command", "command": (env.HOME + "/.claude/hooks/show-usage-limits.sh")}]
      },
      {
        "matcher": "compact",
        "hooks": [{"type": "command", "command": (env.HOME + "/.claude/hooks/show-usage-limits.sh")}]
      }
    ]
  ' "$SETTINGS")
  echo "$MERGED" > "$SETTINGS"
else
  # Create new settings
  jq -n '{
    "$schema": "https://json.schemastore.org/claude-code-settings.json",
    "statusLine": {
      "type": "command",
      "command": ("bash " + env.HOME + "/.claude/statusline-command.sh")
    },
    "hooks": {
      "SessionStart": [
        {
          "matcher": "startup",
          "hooks": [{"type": "command", "command": (env.HOME + "/.claude/hooks/show-usage-limits.sh")}]
        },
        {
          "matcher": "compact",
          "hooks": [{"type": "command", "command": (env.HOME + "/.claude/hooks/show-usage-limits.sh")}]
        }
      ]
    }
  }' > "$SETTINGS"
fi

echo ""
echo "claudeline installed! Restart Claude Code to see your new statusline."
echo "Type /usage inside Claude Code to manually refresh usage limits."
