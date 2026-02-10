#!/bin/bash
# Claude Code Usage Limits Hook
# Fetches and caches 5-hour and 7-day usage limits at session start and after context compaction
# The statusline script reads from this cache

readonly CACHE_FILE="/tmp/.claude_usage_limits.json"

# Colors (for the one-time display)
readonly RESET=$'\033[0m'
readonly DIM=$'\033[2m'
readonly GREEN=$'\033[32m'
readonly YELLOW=$'\033[33m'
readonly RED=$'\033[31m'

# Get OAuth token from macOS Keychain
get_token() {
  local creds
  creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  if [[ -z "$creds" ]]; then
    return 1
  fi
  echo "$creds" | jq -r '.claudeAiOauth.accessToken // empty'
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

  local token
  token=$(get_token)
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
  label5="5hr"
  label7="7d"
  local epoch
  if [[ -n "$reset5" ]]; then
    epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "${reset5%%.*}" "+%s" 2>/dev/null) \
      && label5=$(date -r "$epoch" "+%H:%M" 2>/dev/null) || label5="5hr"
  fi
  if [[ -n "$reset7" ]]; then
    epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "${reset7%%.*}" "+%s" 2>/dev/null) \
      && label7=$(date -r "$epoch" "+%m/%d" 2>/dev/null) || label7="7d"
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
