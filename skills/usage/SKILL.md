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

Two different situations look the same on screen — tell them apart by
whether it clears after your first prompt:

- **Temporary (expected):** a brand-new session has no `rate_limits` yet.
  The segment is blank until your first prompt gets its first API
  response, then the next render shows it and it stays current from
  there.
- **Permanent (upstream, not a claudeline bug):** on some Claude.ai
  Max/OAuth configurations, `rate_limits` never arrives on stdin at all —
  see [anthropics/claude-code#40094](https://github.com/anthropics/claude-code/issues/40094)
  and [#45133](https://github.com/anthropics/claude-code/issues/45133).
  It's also expected on non-Pro/Max plans, where usage limits don't apply.
  claudeline has no fallback for this case — the old fetch path that
  would have papered over it was itself the source of the v0.6.x
  cross-profile leak, so it's gone for good. If the segment is still
  blank after several prompts, the fix has to land in Claude Code
  upstream, not here.
