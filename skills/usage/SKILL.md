---
name: usage
description: Explain how usage limits show up in the statusline. Use when the user asks about /usage, why usage is blank, or how to refresh usage stats.
---

# Usage Limits

There's nothing to refresh — Claude Code hands each session its own 5-hour
and 7-day usage on the statusline's stdin (`rate_limits.five_hour` /
`.seven_day`) on every render, so the statusline just reads it straight off
that input. No fetch, no OAuth token, no cache TTL.

## If the usage segment is blank

Usage arrives with the session's first API response. A brand-new session
(before you've sent a prompt) has no `rate_limits` yet, so the segment is
blank until then — that's expected, not a bug. Send one prompt and the next
statusline render will show it.
