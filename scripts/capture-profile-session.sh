#!/bin/bash
# Copies the active macOS Keychain session into this profile's
# .credentials.json with provenance, so hooks/show-usage-limits.sh can
# read the file first instead of the shared keychain slot. User-run
# only — never invoked by the hook or statusline. Run once per profile
# after /login. See README "Per-profile credentials (macOS)".

# keep in sync with hooks/show-usage-limits.sh + statusline-command.sh
# detect_account() — scripts/test.sh asserts all three copies match
detect_account() {
  ACCOUNT_ASSUMED=0
  if [[ -z "${CLAUDE_CONFIG_DIR+x}" ]]; then
    ACCOUNT_ID="work"
    ACCOUNT_ASSUMED=1
  elif [[ "$CLAUDE_CONFIG_DIR" == *"claude-personal"* ]]; then
    ACCOUNT_ID="personal"
  else
    ACCOUNT_ID="work"
  fi
}
detect_account

if [[ "$ACCOUNT_ASSUMED" == "1" ]]; then
  echo "set CLAUDE_CONFIG_DIR explicitly or run from the profile's session" >&2
  exit 1
fi

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

uuid=$(jq -r '.oauthAccount.accountUuid // empty' "$CONFIG_DIR/.claude.json" 2>/dev/null)
if [[ -z "$uuid" ]]; then
  echo "no accountUuid in $CONFIG_DIR/.claude.json — no provenance possible" >&2
  exit 1
fi

creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
if [[ -z "$creds" ]]; then
  echo "no Claude Code-credentials entry in Keychain" >&2
  exit 1
fi

oauth_blob=$(echo "$creds" | jq -c '.claudeAiOauth' 2>/dev/null)
if [[ -z "$oauth_blob" || "$oauth_blob" == "null" ]]; then
  echo "failed to parse claudeAiOauth from Keychain entry" >&2
  exit 1
fi

captured_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
tmp_file="$CONFIG_DIR/.credentials.json.tmp"
dest_file="$CONFIG_DIR/.credentials.json"

jq -n --argjson oauth "$oauth_blob" --arg uuid "$uuid" --arg at "$captured_at" \
  '{claudeAiOauth: $oauth, claudeline: {captured_for_uuid: $uuid, captured_at: $at}}' \
  > "$tmp_file"

chmod 600 "$tmp_file"
mv "$tmp_file" "$dest_file"

email=$(echo "$oauth_blob" | jq -r '.email // "unknown"')
expiry=$(echo "$oauth_blob" | jq -r '.expiresAt // "unknown"')
echo "Captured session for ${email} (expires ${expiry})"
