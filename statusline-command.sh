#!/bin/bash
# Claude Code statusline - clean, responsive bash
# ← needs staging, → needs commit, ↔ both
# ↑ push, ↓ pull, ⇅ both

# Don't use set -e, we handle errors ourselves

# ─────────────────────────────────────────────────────────────
# Colors
# ─────────────────────────────────────────────────────────────
readonly RESET=$'\033[0m'
readonly DIM=$'\033[2m'
readonly GREEN=$'\033[32m'
readonly YELLOW=$'\033[33m'
readonly RED=$'\033[31m'
readonly CYAN=$'\033[36m'
readonly MAGENTA=$'\033[35m'
readonly MAGENTA_BRIGHT=$'\033[95m'

# ─────────────────────────────────────────────────────────────
# Input parsing
# ─────────────────────────────────────────────────────────────
INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.workspace.current_dir // .workspace.project_dir // .cwd // empty')
[[ -z "$CWD" || ! -d "$CWD" ]] && CWD="$(pwd)"

# Try to get terminal width from shell-written cache, fall back to 80
if [[ -f /tmp/.terminal_cols ]]; then
  COLS=$(cat /tmp/.terminal_cols 2>/dev/null)
  [[ ! "$COLS" =~ ^[0-9]+$ ]] && COLS=80
else
  COLS=${COLUMNS:-80}
fi

# ─────────────────────────────────────────────────────────────
# Usage limits (read from cache populated by SessionStart hook)
# ─────────────────────────────────────────────────────────────
readonly USAGE_CACHE="/tmp/.claude_usage_limits.json"

get_usage_limits() {
  if [[ ! -f "$USAGE_CACHE" ]]; then
    return
  fi

  local five_hour seven_day reset5 reset7
  five_hour=$(jq -r '.five_hour.utilization // 0' "$USAGE_CACHE" 2>/dev/null)
  seven_day=$(jq -r '.seven_day.utilization // 0' "$USAGE_CACHE" 2>/dev/null)
  reset5=$(jq -r '.five_hour.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)
  reset7=$(jq -r '.seven_day.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)

  if [[ -z "$five_hour" || "$five_hour" == "null" ]]; then
    return
  fi

  # Convert reset times from UTC to local display format
  # Strip fractional seconds AND timezone suffix for clean parsing
  local label5="5h" label7="7d" epoch clean_ts
  if [[ -n "$reset5" ]]; then
    clean_ts="${reset5%%[.+]*}"
    epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "$clean_ts" "+%s" 2>/dev/null) \
      && label5=$(date -r "$epoch" "+%-I%p" 2>/dev/null | tr '[:upper:]' '[:lower:]') || label5="5h"
  fi
  if [[ -n "$reset7" ]]; then
    clean_ts="${reset7%%[.+]*}"
    epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "$clean_ts" "+%s" 2>/dev/null) \
      && label7=$(date -r "$epoch" "+%m/%d" 2>/dev/null) || label7="7d"
  fi

  # Utilization values are already percentages (e.g., 15.0 = 15%)
  local pct5 pct7 color5 color7
  pct5=$(awk "BEGIN {printf \"%.0f\", $five_hour}")
  pct7=$(awk "BEGIN {printf \"%.0f\", $seven_day}")

  color5=$GREEN
  ((pct5 >= 80)) && color5=$RED
  ((pct5 >= 50 && pct5 < 80)) && color5=$YELLOW

  color7=$GREEN
  ((pct7 >= 80)) && color7=$RED
  ((pct7 >= 50 && pct7 < 80)) && color7=$YELLOW

  printf '%s%s:%s%s%d%%%s %s%s:%s%s%d%%%s %s│%s' "$DIM" "$label5" "$RESET" "$color5" "$pct5" "$RESET" "$DIM" "$label7" "$RESET" "$color7" "$pct7" "$RESET" "$DIM" "$RESET"
}

# ─────────────────────────────────────────────────────────────
# Context window
# ─────────────────────────────────────────────────────────────
get_context() {
  # Prefer the pre-calculated used_percentage if available
  local percent
  percent=$(echo "$INPUT" | jq -r '.context_window.used_percentage // empty')
  if [[ -n "$percent" && "$percent" != "null" ]]; then
    echo "$percent"
    return
  fi

  # Fallback: calculate manually from token counts
  local size current
  size=$(echo "$INPUT" | jq -r '.context_window.context_window_size // 200000')
  current=$(echo "$INPUT" | jq -r '(.context_window.current_usage // {}) | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))')
  percent=$((size > 0 ? current * 100 / size : 0))
  echo "$percent"
}

progress_bar() {
  local percent=$1 width=${2:-5}

  # Partial block characters (1/8 increments)
  local blocks=(' ' '▏' '▎' '▍' '▌' '▋' '▊' '▉' '█')

  # Calculate filled units (width * 8 possible states)
  local total_units=$((width * 8))
  local filled_units=$((percent * total_units / 100))
  ((filled_units > total_units)) && filled_units=$total_units

  local full_blocks=$((filled_units / 8))
  local partial=$((filled_units % 8))
  local empty=$((width - full_blocks - (partial > 0 ? 1 : 0)))

  local color=$GREEN
  ((percent >= 85)) && color=$RED
  ((percent >= 50 && percent < 85)) && color=$YELLOW

  # Build bar: colored fill + dim empty
  local bar=""
  local i

  # Full blocks
  for ((i = 0; i < full_blocks; i++)); do
    bar+="█"
  done

  # Partial block
  ((partial > 0)) && bar+="${blocks[$partial]}"

  # Empty portion (dim)
  local empty_bar=""
  for ((i = 0; i < empty; i++)); do
    empty_bar+=" "
  done

  printf '%s▕%s%s%s%s%s▏%s' "$RESET" "$color" "$bar" "$RESET" "$DIM" "$empty_bar" "$RESET"
}

# ─────────────────────────────────────────────────────────────
# Git helpers
# ─────────────────────────────────────────────────────────────
is_git_repo() {
  git -C "$CWD" rev-parse --is-inside-work-tree &>/dev/null
}

get_repo_name() {
  basename "$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)"
}

get_repo_url() {
  # Get GitHub repo URL from remote
  local remote_url repo_path
  remote_url=$(git -C "$CWD" remote get-url origin 2>/dev/null)

  # Handle various SSH formats for GitHub (including personal account aliases)
  # Patterns: git@github.com:, git@github.com-personal:, git@personal.github.com:, etc.
  if [[ "$remote_url" =~ ^git@([^:]*github[^:]*):(.+)$ ]]; then
    repo_path="${BASH_REMATCH[2]}"
    remote_url="https://github.com/${repo_path}"
  elif [[ "$remote_url" =~ ^ssh://git@([^/]*github[^/]*)/(.+)$ ]]; then
    repo_path="${BASH_REMATCH[2]}"
    remote_url="https://github.com/${repo_path}"
  fi

  # Remove .git suffix
  remote_url="${remote_url%.git}"

  echo "$remote_url"
}

# OSC 8 hyperlink: \033]8;;URL\033\\TEXT\033]8;;\033\\
hyperlink() {
  local url=$1 text=$2
  printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$url" "$text"
}

get_branch() {
  git -C "$CWD" branch --show-current 2>/dev/null || git -C "$CWD" rev-parse --short HEAD 2>/dev/null
}

get_pr_number() {
  local repo_name=$1 branch=$2
  local cache="/tmp/.claude_pr_cache_${repo_name}"
  local branch_cache="/tmp/.claude_pr_branch_${repo_name}"

  # Check cache
  if [[ -f "$cache" && -f "$branch_cache" ]]; then
    local cached_branch cache_age
    cached_branch=$(cat "$branch_cache" 2>/dev/null)
    cache_age=$(($(date +%s) - $(stat -f%m "$cache" 2>/dev/null || echo 0)))
    if [[ "$cached_branch" == "$branch" && $cache_age -lt 120 ]]; then
      cat "$cache"
      return
    fi
  fi

  # Fetch PR
  local pr_num
  pr_num=$(timeout 2 gh pr view --json number -q '.number' 2>/dev/null || true)
  if [[ -n "$pr_num" ]]; then
    echo "#$pr_num" > "$cache"
    echo "#$pr_num"
  else
    echo "" > "$cache"
  fi
  echo "$branch" > "$branch_cache"
}

get_work_status() {
  local staged=0 unstaged=0
  git -C "$CWD" diff --cached --quiet 2>/dev/null || staged=1
  git -C "$CWD" diff --quiet 2>/dev/null || unstaged=1

  if ((unstaged && staged)); then
    printf '%s↔%s' "$YELLOW" "$RESET"
  elif ((unstaged)); then
    printf '%s←%s' "$YELLOW" "$RESET"
  elif ((staged)); then
    printf '%s→%s' "$GREEN" "$RESET"
  fi
}

get_sync_status() {
  local ahead behind
  ahead=$(git -C "$CWD" rev-list --count @{upstream}..HEAD 2>/dev/null || echo 0)
  behind=$(git -C "$CWD" rev-list --count HEAD..@{upstream} 2>/dev/null || echo 0)

  if ((ahead > 0 && behind > 0)); then
    printf '%s⇅%s' "$CYAN" "$RESET"
  elif ((ahead > 0)); then
    printf '%s↑%s' "$GREEN" "$RESET"
  elif ((behind > 0)); then
    printf '%s↓%s' "$RED" "$RESET"
  fi
}

is_worktree() {
  # Returns 0 (true) if CWD is inside a git worktree (not the main working tree)
  local git_dir common_dir
  git_dir=$(git -C "$CWD" rev-parse --git-dir 2>/dev/null) || return 1
  common_dir=$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null) || return 1

  # Resolve to absolute paths for comparison
  git_dir=$(cd "$CWD" && cd "$git_dir" 2>/dev/null && pwd)
  common_dir=$(cd "$CWD" && cd "$common_dir" 2>/dev/null && pwd)

  [[ "$git_dir" != "$common_dir" ]]
}

truncate() {
  local str=$1 max=$2
  if ((${#str} > max)); then
    echo "${str:0:$((max-1))}…"
  else
    echo "$str"
  fi
}

# ─────────────────────────────────────────────────────────────
# Build output
# ─────────────────────────────────────────────────────────────
build_output() {
  local percent repo branch pr pr_num repo_url pr_link work_status sync_status
  percent=$(get_context)

  # Responsive behavior disabled - always show full format

  if is_git_repo; then
    repo=$(get_repo_name)
    branch=$(get_branch)
    pr=$(get_pr_number "$repo" "$branch")
    work_status=$(get_work_status)
    sync_status=$(get_sync_status)

    # Build PR hyperlink if we have a PR
    pr_link=""
    if [[ -n "$pr" ]]; then
      repo_url=$(get_repo_url)
      pr_num="${pr#\#}"  # Remove # prefix
      if [[ -n "$repo_url" ]]; then
        pr_link=$(hyperlink "${repo_url}/pull/${pr_num}" "$pr")
      else
        pr_link="$pr"
      fi
    fi

    # Full: bar% usage | repo:branch #PR ↔↑
    printf '%s %d%% ' "$(progress_bar "$percent")" "$percent"
    local usage_str
    usage_str=$(get_usage_limits)
    [[ -n "$usage_str" ]] && printf '%s ' "$usage_str"
    if is_worktree; then
      printf '%s⎇%s%s%s:%s%s%s' "$DIM" "$RESET" "$CYAN" "$repo" "$RESET" "$MAGENTA" "$(truncate "$branch" 40)"
    else
      printf '%s%s%s:%s%s' "$CYAN" "$repo" "$RESET" "$MAGENTA" "$(truncate "$branch" 40)"
    fi
    printf '%s' "$RESET"
    [[ -n "$pr" ]] && printf ' %s%s%s' "$MAGENTA_BRIGHT" "$pr_link" "$RESET"
    [[ -n "$work_status$sync_status" ]] && printf ' %s%s' "$work_status" "$sync_status"

  else
    # Not in git - full format
    local folder
    folder=$(basename "$CWD")

    printf '%s %d%% ' "$(progress_bar "$percent")" "$percent"
    local usage_str
    usage_str=$(get_usage_limits)
    [[ -n "$usage_str" ]] && printf '%s ' "$usage_str"
    printf '%s%s%s' "$CYAN" "$folder" "$RESET"
  fi
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────
# Debug: capture full JSON input (disable after testing)
echo "$INPUT" | jq '.' > /tmp/statusline-input.json 2>/dev/null

build_output
exit 0
