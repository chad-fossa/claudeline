---
name: abandoned-keychain-attempt
description: Per-profile keychain isolation was tried (hashed entries) and reverted after a silent 2-month usage-data outage
metadata:
  type: project
---

v0.3.0 introduced a hashed-keychain-entry scheme (`Claude Code-credentials-{hash}`) attempting per-`CLAUDE_CONFIG_DIR` OAuth token isolation on macOS, alongside grep-not-jq token extraction. v0.3.1 reverted it in commit e9295da: the hashed entries only ever held MCP-OAuth data with **empty `accessToken` fields**, and the extraction grep was unanchored, so it matched the hashed (empty) entry instead of falling through to the real Max token on the default `"Claude Code-credentials"` entry. Personal-account usage silently went missing for roughly 2 months before this was caught — no error, just missing/wrong numbers.

Forward-fix landed in v0.3.1 and still present in current code (`hooks/show-usage-limits.sh` lines 36-44): always read the *default* keychain entry (`-s "Claude Code-credentials"`, no hash suffix) and anchor the extraction on `"claudeAiOauth":{"accessToken":...}` specifically, never a bare/unanchored grep. The underlying upstream constraint (anthropics/claude-code#20553 — keychain is one slot, not per-config-dir) is documented as a known limitation rather than worked around.

**Do not re-attempt per-profile keychain isolation without first re-verifying #20553 is still open upstream** (do not trust memory of its status — check live). If it has been resolved upstream, that changes the calculus entirely; if not, any new isolation attempt should be checked against this exact failure mode (empty-token entries silently shadowing the real one) before shipping.

Linux never had this problem: `$CLAUDE_CONFIG_DIR/.credentials.json` is a plain per-profile file, no keychain, no collision — see [[leak-inventory]] item 1.
