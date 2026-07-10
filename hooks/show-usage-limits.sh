#!/bin/bash
# Claude Code Usage Limits Hook
# Fetches and caches 5-hour and 7-day usage limits at session start and after context compaction
# The statusline script reads from this cache

# Per-account cache — detect from CLAUDE_CONFIG_DIR or default to "work"
# keep in sync with statusline-command.sh detect_account() — scripts/test.sh asserts they match
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
_ACCT_ID="$ACCOUNT_ID"

if [[ "$_ACCT_ID" == "personal" ]]; then
  _CREDS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude-personal}"
else
  _CREDS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
fi
readonly CACHE_FILE="/tmp/.claude_usage_limits_${_ACCT_ID}.json"

# Colors (for the one-time display)
readonly RESET=$'\033[0m'
readonly DIM=$'\033[2m'
readonly GREEN=$'\033[32m'
readonly YELLOW=$'\033[33m'
readonly RED=$'\033[31m'

# Cross-platform date helpers
if [[ "$OSTYPE" == "darwin"* ]]; then
  parse_iso_utc() { TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "$1" "+%s" 2>/dev/null; }
  fmt_epoch()     { date -r "$1" "$2" 2>/dev/null; }
else
  parse_iso_utc() { date -u -d "$1" "+%s" 2>/dev/null; }
  fmt_epoch()     { date -d "@$1" "$2" 2>/dev/null; }
fi

# Get OAuth token: this profile's .credentials.json FIRST on every platform
# (claudeline-owned refresh via refresh_token_grant), macOS Keychain as
# fallback only when the file is absent (Darwin only; Linux returns 1).
# Sets globals TOKEN and TOKEN_SOURCE (file | file-refresh-failed | keychain |
# unknown) instead of echoing — a caller wrapping this in $(...) would lose
# TOKEN_SOURCE to the command-substitution subshell.
get_token() {
  TOKEN=""
  TOKEN_SOURCE="unknown"
  local creds_file="${_CREDS_DIR}/.credentials.json"

  if [[ -f "$creds_file" ]]; then
    local access_token
    access_token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)

    if [[ -n "$access_token" ]]; then
      local expires_at refresh_expires_at now_ms
      expires_at=$(jq -r '.claudeAiOauth.expiresAt // empty' "$creds_file" 2>/dev/null)
      refresh_expires_at=$(jq -r '.claudeAiOauth.refreshTokenExpiresAt // empty' "$creds_file" 2>/dev/null)
      now_ms=$(( $(date +%s) * 1000 ))

      if [[ -n "$expires_at" && "$expires_at" -gt $((now_ms + 60000)) ]]; then
        TOKEN_SOURCE="file"
        TOKEN="$access_token"
        return 0
      fi

      if [[ -n "$refresh_expires_at" && "$refresh_expires_at" -lt "$now_ms" ]]; then
        TOKEN_SOURCE="file-refresh-failed"
        REFRESH_FAIL_REASON="refresh_token_expired"
        return 1
      fi

      if refresh_token_grant; then
        TOKEN_SOURCE="file"
        TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        return 0
      fi

      TOKEN_SOURCE="file-refresh-failed"
      return 1
    fi
  fi

  if [[ "$OSTYPE" == "darwin"* ]]; then
    # The Claude Max OAuth token lives in "Claude Code-credentials" regardless of
    # CLAUDE_CONFIG_DIR — keychain isn't isolated per config dir, last /login wins.
    # Hashed entries (Claude Code-credentials-{hash}) only hold MCP tokens with
    # empty accessToken fields, not the Max claudeAiOauth we need.
    # jq can fail on MCP-bloated entries truncated at keychain's output limit, so use grep.
    TOKEN_SOURCE="keychain"
    local creds
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1
    TOKEN=$(echo "$creds" | grep -o '"claudeAiOauth":{"accessToken":"[^"]*"' \
      | head -1 \
      | sed 's/"claudeAiOauth":{"accessToken":"//;s/"$//')
  else
    return 1
  fi
}

# Refresh the file-based OAuth token by POSTing the stored refresh_token
# to Anthropic's OAuth endpoint. Refuses on ACCOUNT_ASSUMED (no writes on
# a guessed identity) and when another refresh is already in flight
# (mkdir-based lock — wraps the whole read/POST/write critical section;
# mkdir over statusline's touch+age guard because this section WRITES
# credentials and needs true mutual exclusion, not a stampede guard).
# Sets REFRESH_FAIL_REASON on failure. Never falls back to Keychain.
refresh_token_grant() {
  REFRESH_FAIL_REASON=""
  local creds_file="${_CREDS_DIR}/.credentials.json"

  if [[ "$ACCOUNT_ASSUMED" == "1" ]]; then
    REFRESH_FAIL_REASON="account_assumed"
    return 1
  fi

  local lock_dir="/tmp/.claude_cred_lock_${ACCOUNT_ID}"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    REFRESH_FAIL_REASON="lock_held"
    return 1
  fi

  local refresh_token client_id scopes
  refresh_token=$(jq -r '.claudeAiOauth.refreshToken // empty' "$creds_file" 2>/dev/null)
  client_id=$(jq -r '.claudeAiOauth.clientId // "9d1c250a-e61b-44d9-88ed-5944d1962f5e"' "$creds_file" 2>/dev/null)
  scopes=$(jq -r '(.claudeAiOauth.scopes // []) | join(" ")' "$creds_file" 2>/dev/null)

  if [[ -z "$refresh_token" ]]; then
    REFRESH_FAIL_REASON="no_refresh_token"
    rmdir "$lock_dir" 2>/dev/null
    return 1
  fi

  cp "$creds_file" "${creds_file}.bak"

  local body response http_code payload
  body=$(jq -n --arg rt "$refresh_token" --arg cid "$client_id" --arg scope "$scopes" \
    '{grant_type: "refresh_token", refresh_token: $rt, client_id: $cid, scope: $scope}')

  response=$(curl -s -w '\n%{http_code}' --max-time 5 \
    -X POST "https://platform.claude.com/v1/oauth/token" \
    -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null)
  http_code="${response##*$'\n'}"
  payload="${response%$'\n'*}"

  if [[ "$http_code" != "200" ]] || ! echo "$payload" | jq -e . >/dev/null 2>&1; then
    REFRESH_FAIL_REASON="http_${http_code:-timeout}"
    rmdir "$lock_dir" 2>/dev/null
    return 1
  fi

  local access_token new_refresh_token expires_in now_ms new_expires_at
  access_token=$(echo "$payload" | jq -r '.access_token // empty')
  new_refresh_token=$(echo "$payload" | jq -r '.refresh_token // empty')
  expires_in=$(echo "$payload" | jq -r '.expires_in // empty')

  if [[ -z "$access_token" || -z "$expires_in" ]]; then
    REFRESH_FAIL_REASON="parse_failure"
    rmdir "$lock_dir" 2>/dev/null
    return 1
  fi

  [[ -z "$new_refresh_token" ]] && new_refresh_token="$refresh_token"
  now_ms=$(( $(date +%s) * 1000 ))
  new_expires_at=$(( now_ms + expires_in * 1000 ))

  local tmp_file="${creds_file}.tmp"
  jq --arg at "$access_token" --arg rt "$new_refresh_token" --argjson exp "$new_expires_at" \
    '.claudeAiOauth.accessToken = $at | .claudeAiOauth.refreshToken = $rt | .claudeAiOauth.expiresAt = $exp' \
    "$creds_file" > "$tmp_file"
  chmod 600 "$tmp_file"
  mv "$tmp_file" "$creds_file"

  rmdir "$lock_dir" 2>/dev/null
  return 0
}

# Reads the "Claude Code-credentials" keychain item's modification date
# WITHOUT -w (metadata only, never the secret payload) and returns it as
# epoch seconds. Used only for the auto-capture corroboration window
# (maybe_auto_capture) — never as a token source.
read_keychain_mdat_epoch() {
  local raw ts
  raw=$(security find-generic-password -s "Claude Code-credentials" 2>/dev/null)
  [[ -z "$raw" ]] && return 1
  # Real `security` output embeds a raw NUL right after the timestamp
  # (e.g. "mdat"<timedate>=0x...  "20260710042146Z\0"); bash's command
  # substitution above already strips it on capture, so match the bare
  # digits+Z run rather than depending on exact quote/whitespace
  # placement afterward — -a is defense-in-depth for any shell that
  # doesn't strip it, verified against a real macOS Keychain entry.
  ts=$(echo "$raw" | grep -a '"mdat"' | grep -a -o '[0-9]\{14\}Z' | head -1)
  [[ -z "$ts" ]] && return 1
  if [[ "$OSTYPE" == "darwin"* ]]; then
    TZ=UTC date -jf "%Y%m%d%H%M%SZ" "$ts" "+%s" 2>/dev/null
  else
    date -u -d "${ts:0:4}-${ts:4:2}-${ts:6:2}T${ts:8:2}:${ts:10:2}:${ts:12:2}Z" "+%s" 2>/dev/null
  fi
}

# Prefers this profile's own capture script (sibling of _CREDS_DIR, mirrors
# resolve_usage_refresh_hook()'s CLAUDE_CONFIG_DIR-first resolution),
# falling back to the work install. install.sh does not currently ship
# scripts/capture-profile-session.sh, so this commonly falls through to a
# path that doesn't exist — maybe_auto_capture treats that as a loud,
# non-fatal skip, not an error.
resolve_capture_script() {
  local preferred="${_CREDS_DIR}/scripts/capture-profile-session.sh"
  if [[ -f "$preferred" ]]; then
    echo "$preferred"
  else
    echo "$HOME/.claude/scripts/capture-profile-session.sh"
  fi
}

# Auto-capture ("/login is all I do"): fires when this profile's
# .claude.json .oauthAccount.profileFetchedAt VALUE-CHANGES relative to
# the credentials file's claudeline.captured_login_at (or the file is
# absent) — never mtime, which churns on unrelated .claude.json writes.
# Gated by a TWO-SIDED corroboration window against the keychain item's
# mdat: a one-sided window (only bounding how much LATER the keychain
# write can be) is satisfiable by a second profile's concurrent login —
# P logs in, Q logs in ~90s later in the OTHER profile, and Q's fresh
# keychain token gets captured into P's file under P's own legitimate
# stamp, no adversarial timing required (multi-profile-isolation review,
# 2026-07-10). Bounding both directions shrinks that race window; it
# can't close it — timestamp proximity on one shared mutable resource
# can't prove causal ownership between two independent event streams.
# That residual is accepted; a real identity probe happens downstream in
# capture-profile-session.sh itself (Task 7).
# Wraps the whole check+veto+invoke in the SAME lock refresh_token_grant
# uses, so auto-capture and an in-flight refresh can't race the file.
# Capture failure (missing script, capture script's own exit != 0) never
# breaks the render path — always returns 0 and lets main() continue to
# get_token().
maybe_auto_capture() {
  [[ "$ACCOUNT_ASSUMED" == "1" ]] && return 0
  [[ "$OSTYPE" != "darwin"* ]] && return 0

  local claude_json="${_CREDS_DIR}/.claude.json"
  local creds_file="${_CREDS_DIR}/.credentials.json"

  local profile_fetched_at
  profile_fetched_at=$(jq -r '.oauthAccount.profileFetchedAt // empty' "$claude_json" 2>/dev/null)
  [[ -z "$profile_fetched_at" ]] && return 0

  local captured_login_at=""
  [[ -f "$creds_file" ]] && captured_login_at=$(jq -r '.claudeline.captured_login_at // empty' "$creds_file" 2>/dev/null)
  [[ "$profile_fetched_at" == "$captured_login_at" ]] && return 0

  local lock_dir="/tmp/.claude_cred_lock_${ACCOUNT_ID}"
  mkdir "$lock_dir" 2>/dev/null || return 0

  local window="${CLAUDELINE_CAPTURE_WINDOW_SECS:-30}"
  local mdat_epoch profile_fetched_sec delta
  mdat_epoch=$(read_keychain_mdat_epoch)
  if [[ -z "$mdat_epoch" ]]; then
    rmdir "$lock_dir" 2>/dev/null
    return 0
  fi
  profile_fetched_sec=$((profile_fetched_at / 1000))
  delta=$((mdat_epoch - profile_fetched_sec))
  ((delta < 0)) && delta=$((-delta))

  local cap_uuid cap_email
  cap_uuid=$(jq -r '.oauthAccount.accountUuid // "unknown"' "$claude_json" 2>/dev/null)
  cap_email=$(jq -r '.oauthAccount.emailAddress // .oauthAccount.email // "unknown"' "$claude_json" 2>/dev/null)

  if ((delta > window)); then
    local artifact="/tmp/.claude_cred_capture_vetoed_${ACCOUNT_ID}"
    printf '%s auto_capture_veto delta=%ss window=%ss profileFetchedAt=%s mdat=%s uuid=%s email=%s\n' \
      "$(date +%s)" "$delta" "$window" "$profile_fetched_at" "$mdat_epoch" "$cap_uuid" "$cap_email" > "$artifact"
    echo "${DIM}Usage: auto-capture vetoed for ${cap_email} (${cap_uuid}) — keychain/login timing outside ${window}s window (delta=${delta}s)${RESET}" >&2
    rmdir "$lock_dir" 2>/dev/null
    return 0
  fi

  local capture_script
  capture_script=$(resolve_capture_script)
  if [[ ! -f "$capture_script" ]]; then
    echo "${DIM}Usage: auto-capture skipped for ${cap_email} (${cap_uuid}) — capture script not found at ${capture_script}${RESET}" >&2
    rmdir "$lock_dir" 2>/dev/null
    return 0
  fi

  echo "${DIM}Usage: auto-capturing session for ${cap_email} (${cap_uuid})${RESET}" >&2
  CLAUDE_CONFIG_DIR="$_CREDS_DIR" bash "$capture_script" >/dev/null 2>&1

  rmdir "$lock_dir" 2>/dev/null
  return 0
}

# Fetch usage limits from API
fetch_usage() {
  local token=$1
  curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "User-Agent: claude-code/2.0.32" \
    -H "Authorization: Bearer ${token}" \
    -H "anthropic-beta: oauth-2025-04-20"
}

# Format utilization with color (util is already a percentage, e.g., 15.0 = 15%)
format_util() {
  local util=$1
  local percent
  percent=$(awk "BEGIN {printf \"%.0f\", $util}")

  local color=$GREEN
  ((percent >= 80)) && color=$RED
  ((percent >= 50 && percent < 80)) && color=$YELLOW

  printf '%s%d%%%s' "$color" "$percent" "$RESET"
}

# Mini progress bar for initial display (util is already a percentage)
mini_bar() {
  local util=$1 width=10
  local percent
  percent=$(awk "BEGIN {printf \"%.0f\", $util}")

  local filled=$((percent * width / 100))
  ((filled > width)) && filled=$width
  local empty=$((width - filled))

  local color=$GREEN
  ((percent >= 80)) && color=$RED
  ((percent >= 50 && percent < 80)) && color=$YELLOW

  local bar=""
  ((filled > 0)) && bar=$(printf '█%.0s' $(seq 1 $filled))
  local empty_bar=""
  ((empty > 0)) && empty_bar=$(printf '░%.0s' $(seq 1 $empty))

  printf '%s%s%s%s' "$color" "$bar" "$DIM$empty_bar" "$RESET"
}

# A failed file-based refresh never falls back to Keychain silently: drop a
# loud artifact, merge token_source into whatever cache already exists
# (leaving its numbers untouched), and let the render continue on stale data.
handle_refresh_failure() {
  local reason="${REFRESH_FAIL_REASON:-unknown}"
  local artifact="/tmp/.claude_cred_refresh_failed_${ACCOUNT_ID}"
  printf '%s %s\n' "$(date +%s)" "$reason" > "$artifact"

  if [[ -f "$CACHE_FILE" ]]; then
    local merged
    merged=$(jq '. + {token_source: "file-refresh-failed"}' "$CACHE_FILE" 2>/dev/null)
    [[ -n "$merged" ]] && echo "$merged" > "$CACHE_FILE"
  else
    jq -n '{token_source: "file-refresh-failed"}' > "$CACHE_FILE"
  fi

  echo "${DIM}Usage: credential refresh failed (${reason})${RESET}" >&2
}

# Main
main() {
  # Read hook input (contains session info)
  local input
  input=$(cat)

  maybe_auto_capture
  get_token
  local token="$TOKEN"
  if [[ -z "$token" ]]; then
    if [[ "$TOKEN_SOURCE" == "file-refresh-failed" ]]; then
      handle_refresh_failure
    else
      echo "${DIM}Usage: Could not get credentials${RESET}" >&2
    fi
    exit 0
  fi

  local usage
  usage=$(fetch_usage "$token")
  if [[ -z "$usage" ]] || ! echo "$usage" | jq -e . >/dev/null 2>&1; then
    echo "${DIM}Usage: API request failed${RESET}" >&2
    exit 0
  fi

  # Write to cache file with timestamp
  local cache_data
  cache_data=$(echo "$usage" | jq --arg ts "$(date +%s)" --arg src "$TOKEN_SOURCE" \
    '. + {fetched_at: ($ts | tonumber), token_source: $src}')
  echo "$cache_data" > "$CACHE_FILE"

  # Parse for display
  local five_hour_util seven_day_util reset5 reset7 label5 label7
  five_hour_util=$(echo "$usage" | jq -r '.five_hour.utilization // 0')
  seven_day_util=$(echo "$usage" | jq -r '.seven_day.utilization // 0')
  reset5=$(echo "$usage" | jq -r '.five_hour.resets_at // empty')
  reset7=$(echo "$usage" | jq -r '.seven_day.resets_at // empty')

  # Convert reset times from UTC to local display format
  # Strip fractional seconds AND timezone suffix to get clean datetime for parsing
  label5="5hr"
  label7="7d"
  local epoch clean_ts
  if [[ -n "$reset5" ]]; then
    clean_ts="${reset5%%[.+]*}"  # Strip .fractional and +00:00
    epoch=$(parse_iso_utc "$clean_ts") \
      && label5=$(fmt_epoch "$epoch" "+%-I%p" | tr '[:upper:]' '[:lower:]') || label5="5hr"
  fi
  if [[ -n "$reset7" ]]; then
    clean_ts="${reset7%%[.+]*}"
    epoch=$(parse_iso_utc "$clean_ts") \
      && label7=$(fmt_epoch "$epoch" "+%m/%d") || label7="7d"
  fi

  # Brief one-line display
  printf '%s%s:%s %s %s  %s%s:%s %s %s\n' \
    "$DIM" "$label5" "$RESET" \
    "$(mini_bar "$five_hour_util")" \
    "$(format_util "$five_hour_util")" \
    "$DIM" "$label7" "$RESET" \
    "$(mini_bar "$seven_day_util")" \
    "$(format_util "$seven_day_util")"
}

main
exit 0
