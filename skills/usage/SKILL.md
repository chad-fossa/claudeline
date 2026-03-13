---
name: usage
description: Refresh Claude Code usage limits in the statusline. Use when the user runs /usage, wants to check usage, refresh usage stats, or see remaining quota.
---

# Refresh Usage Limits

Fetches the current 5-hour and 7-day usage limits from Anthropic's API and updates the statusline cache for the active account.

## Instructions

Run the usage limits hook script (pipe empty input since it normally receives hook JSON on stdin):

```bash
echo '{}' | ~/.claude/hooks/show-usage-limits.sh
```

This will:
1. Detect the active account from `CLAUDE_CONFIG_DIR`
2. Fetch current usage from Anthropic's OAuth API
3. Update the cache at `/tmp/.claude_usage_limits_<account>.json`
4. Display the current usage percentages

The statusline will reflect the updated values on the next render.
