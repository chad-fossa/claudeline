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

# Same runtime dir hooks/show-usage-limits.sh uses — inlined here
# identically (standalone script). See that file for the full rationale
# (world-writable /tmp squat/symlink surface).
RUNTIME_DIR="/tmp/claudeline-$(id -u)"
mkdir -p "$RUNTIME_DIR" 2>/dev/null
chmod 700 "$RUNTIME_DIR" 2>/dev/null
readonly RUNTIME_DIR

# Same lock hooks/show-usage-limits.sh uses for refresh_token_grant and
# maybe_auto_capture — inlined here byte-identically (standalone script,
# can't source the hook) so manual capture can't race an in-flight
# refresh. scripts/test.sh asserts the two copies stay in sync.
cred_lock_dir() {
  printf '%s/.claude_cred_lock_%s' "$RUNTIME_DIR" "$ACCOUNT_ID"
}

acquire_cred_lock() {
  local lock_dir
  lock_dir=$(cred_lock_dir)

  if [[ -d "$lock_dir" ]]; then
    local now mtime age
    now=$(date +%s)
    mtime=$(stat -f%m "$lock_dir" 2>/dev/null || stat -c%Y "$lock_dir" 2>/dev/null || echo "$now")
    age=$((now - mtime))
    ((age > 120)) && rmdir "$lock_dir" 2>/dev/null
  fi

  mkdir "$lock_dir" 2>/dev/null || return 1
  _CRED_LOCK_PREV_TRAP=$(trap -p EXIT)
  trap 'rmdir "'"$lock_dir"'" 2>/dev/null' EXIT
  return 0
}

release_cred_lock() {
  rmdir "$(cred_lock_dir)" 2>/dev/null
  if [[ -n "$_CRED_LOCK_PREV_TRAP" ]]; then
    eval "$_CRED_LOCK_PREV_TRAP"
  else
    trap - EXIT
  fi
  _CRED_LOCK_PREV_TRAP=""
}

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

# Prefer the value the hook's auto-capture trigger already read
# (CLAUDELINE_PROFILE_FETCHED_AT) over re-reading .claude.json here — that
# removes a TOCTOU window between the trigger's read and this script's own
# stamp read, where .claude.json could change between the two. Manual runs
# (no env var set) still read the file directly.
profile_fetched_at="${CLAUDELINE_PROFILE_FETCHED_AT:-}"
if [[ -z "$profile_fetched_at" ]]; then
  profile_fetched_at=$(jq -r '.oauthAccount.profileFetchedAt // empty' "$CONFIG_DIR/.claude.json" 2>/dev/null)
fi
profile_email=$(jq -r '.oauthAccount.emailAddress // .oauthAccount.email // "unknown"' "$CONFIG_DIR/.claude.json" 2>/dev/null)

# Same lock refresh_token_grant/maybe_auto_capture hold in the hook, so a
# manual capture can't race an in-flight refresh. A held lock means one of
# those is already touching this account's credentials file — skip loudly
# rather than wait or corrupt the write.
if ! acquire_cred_lock; then
  echo "capture skipped: credential lock held by an in-flight refresh/capture — try again shortly" >&2
  exit 1
fi

creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
if [[ -z "$creds" ]]; then
  echo "no Claude Code-credentials entry in Keychain" >&2
  release_cred_lock
  exit 1
fi

oauth_blob=$(echo "$creds" | jq -c '.claudeAiOauth' 2>/dev/null)
if [[ -z "$oauth_blob" || "$oauth_blob" == "null" ]]; then
  echo "failed to parse claudeAiOauth from Keychain entry" >&2
  release_cred_lock
  exit 1
fi

# Identity verification probe (Task 7). Confirms the keychain session we're
# about to capture actually belongs to THIS profile's account before we
# stamp it as verified — captured_for_uuid alone (the profile's own uuid,
# stamped by construction) can never prove that; only an independent
# server-side lookup of the token's real owner can. Sets VERIFY_STATUS to
# one of: verified | mismatch | unverified. Kept in one place (this script)
# so hooks/show-usage-limits.sh's auto-capture trigger (Task 8) calls this
# script rather than duplicating the probe.
verify_capture_identity() {
  local token=$1 expect_uuid=$2
  VERIFY_STATUS="unverified"
  PROBE_UUID=""
  PROBE_EMAIL=""

  # Bearer header via -H @<600-tmp-file>, same reasoning as
  # hooks/show-usage-limits.sh's fetch_usage — a -H value is visible on
  # this process's argv for as long as curl runs; a file curl reads isn't.
  local header_file
  header_file=$(mktemp)
  chmod 600 "$header_file"
  printf 'Authorization: Bearer %s\n' "$token" > "$header_file"

  local response http_code payload
  response=$(curl -s -w '\n%{http_code}' --max-time 5 \
    -H @"$header_file" \
    -H "Content-Type: application/json" \
    "https://api.anthropic.com/api/oauth/profile" 2>/dev/null)
  rm -f "$header_file"
  http_code="${response##*$'\n'}"
  payload="${response%$'\n'*}"

  [[ "$http_code" != "200" ]] && return 0
  echo "$payload" | jq -e . >/dev/null 2>&1 || return 0

  PROBE_UUID=$(echo "$payload" | jq -r '.uuid // .account_uuid // empty')
  PROBE_EMAIL=$(echo "$payload" | jq -r '.email // "unknown"')
  [[ -z "$PROBE_UUID" ]] && return 0

  if [[ "$PROBE_UUID" == "$expect_uuid" ]]; then
    VERIFY_STATUS="verified"
  else
    VERIFY_STATUS="mismatch"
  fi
}

access_token=$(echo "$oauth_blob" | jq -r '.accessToken // empty')
verify_capture_identity "$access_token" "$uuid"

if [[ "$VERIFY_STATUS" == "mismatch" ]]; then
  artifact="${RUNTIME_DIR}/.claude_cred_capture_vetoed_${ACCOUNT_ID}"
  printf '%s reason=identity_mismatch profile_uuid=%s probe_uuid=%s profile_email=%s probe_email=%s\n' \
    "$(date +%s)" "$uuid" "$PROBE_UUID" "$profile_email" "$PROBE_EMAIL" > "$artifact"
  echo "capture VETOED: keychain session belongs to a different account than this profile (profile uuid=${uuid} email=${profile_email}; keychain probe uuid=${PROBE_UUID} email=${PROBE_EMAIL})" >&2
  release_cred_lock
  exit 1
fi

captured_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
tmp_file="$CONFIG_DIR/.credentials.json.tmp"
dest_file="$CONFIG_DIR/.credentials.json"

# umask 077 for the window between jq's write and chmod 600 below —
# without it the tmp file briefly exists at the process's default (often
# world-readable) mode before chmod catches up.
if [[ "$VERIFY_STATUS" == "verified" ]]; then
  (
    umask 077
    jq -n --argjson oauth "$oauth_blob" --arg uuid "$uuid" --arg at "$captured_at" \
      --arg login_at "$profile_fetched_at" --arg verified_at "$captured_at" \
      '{claudeAiOauth: $oauth, claudeline: {captured_for_uuid: $uuid, captured_at: $at,
        captured_login_at: (if $login_at == "" then null else $login_at end),
        verified_account_uuid: $uuid, verified_at: $verified_at}}' \
      > "$tmp_file"
  )
else
  echo "capture unverified: identity probe unavailable (timeout/non-200/unparseable) — file usable but ? stays until a verified capture" >&2
  (
    umask 077
    jq -n --argjson oauth "$oauth_blob" --arg uuid "$uuid" --arg at "$captured_at" \
      --arg login_at "$profile_fetched_at" \
      '{claudeAiOauth: $oauth, claudeline: {captured_for_uuid: $uuid, captured_at: $at,
        captured_login_at: (if $login_at == "" then null else $login_at end)}}' \
      > "$tmp_file"
  )
fi

chmod 600 "$tmp_file"
mv "$tmp_file" "$dest_file"
release_cred_lock

email=$(echo "$oauth_blob" | jq -r '.email // "unknown"')
expiry=$(echo "$oauth_blob" | jq -r '.expiresAt // "unknown"')
echo "Captured session for ${email} (expires ${expiry})"
