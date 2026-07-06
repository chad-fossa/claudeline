---
name: diff-test-recipe
description: How to actually verify (not reason about) whether usage-limit state bleeds between work and personal profiles
metadata:
  type: reference
---

Never accept "should be fine" as a conclusion for a cross-profile leak claim — run this and diff the output:

```
CLAUDE_CONFIG_DIR=$HOME/.claude bash hooks/show-usage-limits.sh
CLAUDE_CONFIG_DIR=$HOME/.claude-personal bash hooks/show-usage-limits.sh
diff /tmp/.claude_usage_limits_work.json /tmp/.claude_usage_limits_personal.json
```

Identical numbers in both files (when the two accounts' actual usage differs) confirms the keychain single-slot leak ([[leak-inventory]] item 1) is live, not theoretical. For the PR-cache leak (item 2), the equivalent check is opening the same repo path under both `CLAUDE_CONFIG_DIR` values and confirming both statuslines read `/tmp/.claude_pr_cache_${repo_name}` — same file, no account suffix — rather than diffing two files.

Any finding reported without this recipe (or the PR-cache equivalent) having been run should be flagged as unverified in the output.
