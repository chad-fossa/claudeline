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

# Fetch usage limits from API
fetch_usage() {
  local token=$1
  curl -s "https://api.anthropic.com/api/oauth/usage" \
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

# Main
main() {
  # Read hook input (contains session info)
  local input
  input=$(cat)

  get_token
  local token="$TOKEN"
  if [[ -z "$token" ]]; then
    echo "${DIM}Usage: Could not get credentials${RESET}" >&2
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
  cache_data=$(echo "$usage" | jq --arg ts "$(date +%s)" '. + {fetched_at: ($ts | tonumber)}')
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
