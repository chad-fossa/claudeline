---
name: usage
description: Refresh Claude Code usage limits in the statusline. Use when the user runs /usage, wants to check usage, refresh usage stats, or see remaining quota.
---

# Refresh Usage Limits

Fetches the current 5-hour and 7-day usage limits from Anthropic's API and updates the statusline cache.

## Instructions

Run the usage limits hook script:

```bash
/Users/chadfurman/.claude/hooks/show-usage-limits.sh
```

This will:
1. Fetch current usage from Anthropic's OAuth API
2. Update the cache at `/tmp/.claude_usage_limits.json`
3. Display the current usage percentages

The statusline will reflect the updated values on the next render.
