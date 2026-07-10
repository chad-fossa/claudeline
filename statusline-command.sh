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
# Cross-platform helpers (BSD on macOS, GNU on Linux)
# ─────────────────────────────────────────────────────────────
if [[ "$OSTYPE" == "darwin"* ]]; then
  fmt_epoch()     { date -r "$1" "$2" 2>/dev/null; }
  file_mtime()    { stat -f%m "$1" 2>/dev/null; }
else
  fmt_epoch()     { date -d "@$1" "$2" 2>/dev/null; }
  file_mtime()    { stat -c%Y "$1" 2>/dev/null; }
fi

# ─────────────────────────────────────────────────────────────
# Input parsing
# ─────────────────────────────────────────────────────────────
INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.workspace.current_dir // .workspace.project_dir // .cwd // empty')
[[ -z "$CWD" || ! -d "$CWD" ]] && CWD="$(pwd)"

# ─────────────────────────────────────────────────────────────
# Account detection (work vs personal via config dir)
# Customize labels via env vars in .zshrc:
#   CLAUDE_ACCOUNT_WORK_LABEL="W"        (default: "W")
#   CLAUDE_ACCOUNT_PERSONAL_LABEL="P"    (default: "P")
#   CLAUDE_ACCOUNT_WORK_COLOR="\033[36m" (default: cyan)
#   CLAUDE_ACCOUNT_PERSONAL_COLOR="\033[35m" (default: magenta)
# ─────────────────────────────────────────────────────────────
# Detect from CLAUDE_CONFIG_DIR env var (set by shell alias), not transcript_path
# (transcript_path follows symlinks, so personal→work projects resolve to /.claude/)
# Sole copy since v0.7.0 — usage now arrives on stdin, so there's no
# separate hook/capture script needing an identical copy to stay in sync.
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

if [[ "$ACCOUNT_ID" == "personal" ]]; then
  ACCOUNT_LABEL="${CLAUDE_ACCOUNT_PERSONAL_LABEL:-P}"
  ACCOUNT_COLOR="${CLAUDE_ACCOUNT_PERSONAL_COLOR:-$MAGENTA}"
else
  ACCOUNT_LABEL="${CLAUDE_ACCOUNT_WORK_LABEL:-W}"
  ACCOUNT_COLOR="${CLAUDE_ACCOUNT_WORK_COLOR:-$CYAN}"
fi

# Try to get terminal width from shell-written cache, fall back to 80.
# /tmp/.terminal_cols is written by the user's own shell config (not
# claudeline), so it stays at the bare /tmp path it's always used —
# moving it would break existing dotfile setups that write there.
if [[ -f /tmp/.terminal_cols ]]; then
  COLS=$(cat /tmp/.terminal_cols 2>/dev/null)
  [[ ! "$COLS" =~ ^[0-9]+$ ]] && COLS=80
else
  COLS=${COLUMNS:-80}
fi

# Every cache/lock statusline writes lives under this per-user 0700
# runtime dir, not bare /tmp.
RUNTIME_DIR="/tmp/claudeline-$(id -u)"
mkdir -p -m 700 "$RUNTIME_DIR" 2>/dev/null
readonly RUNTIME_DIR

# /tmp is world-writable, so mkdir -p above only guarantees SOME directory
# now exists at this path — not that WE created it or own it. Any process
# (a co-tenant, or a race before this script's first run) can pre-create
# /tmp/claudeline-<uid> (the name embeds a uid, not proof of who made it)
# or swap it for a symlink into a directory it controls; owning that
# directory means owning every lock/artifact/sentinel/cache claudeline
# writes under it. Verify ownership (and rule out a symlink, which -d
# would follow and -O would validate against the SYMLINK TARGET's owner,
# not the path itself) before trusting anything under RUNTIME_DIR this run.
verify_runtime_dir() {
  RUNTIME_DIR_SAFE=1
  if [[ -L "$RUNTIME_DIR" || ! -d "$RUNTIME_DIR" || ! -O "$RUNTIME_DIR" ]]; then
    echo "claudeline: refusing to use ${RUNTIME_DIR} — it isn't a directory we own (pre-created or symlinked by another process); lock/artifact/sentinel/cache writes disabled for this run" >&2
    RUNTIME_DIR_SAFE=0
    return
  fi

  # mkdir -m 700 only applies at CREATE time — an already-existing dir we
  # own (pre-created by another process, or left behind with a
  # misconfigured umask) can still be group/other-writable, letting any
  # co-tenant read or race every lock/artifact/cache written under it.
  local mode
  mode=$(stat -f%Lp "$RUNTIME_DIR" 2>/dev/null || stat -c%a "$RUNTIME_DIR" 2>/dev/null)
  if [[ "$mode" =~ ^[0-7]+$ ]] && (( (8#$mode) & 8#077 )); then
    echo "claudeline: refusing to use ${RUNTIME_DIR} — group/other-accessible permissions (${mode}, expected 700); lock/artifact/sentinel/cache writes disabled for this run" >&2
    RUNTIME_DIR_SAFE=0
  fi
}
verify_runtime_dir
readonly RUNTIME_DIR_SAFE

# ─────────────────────────────────────────────────────────────
# Usage limits — Claude Code hands each session its OWN usage on stdin
# (rate_limits.five_hour/.seven_day), so there's nothing to fetch: read
# it straight off $INPUT, render it, and cache it synchronously for the
# rare render where stdin arrives before the session's first API
# response. Cache schema mirrors stdin verbatim; resets_at is a raw
# epoch int, not a string to parse.
# ─────────────────────────────────────────────────────────────
readonly USAGE_CACHE="${RUNTIME_DIR}/.claude_usage_limits_${ACCOUNT_ID}.json"

write_usage_cache() {
  [[ "$RUNTIME_DIR_SAFE" != "1" ]] && return
  # Never persist a GUESSED identity's numbers — same refusal the
  # deleted refresh_token_grant made on ACCOUNT_ASSUMED. An env-less
  # session that guesses "work" and writes its own usage into the work
  # cache file poisons a later, genuinely-detected work session, which
  # would then render the guess as its own numbers, undimmed. Rendering
  # from stdin this run is unaffected — only the write is gated.
  ((ACCOUNT_ASSUMED)) && return
  local five_pct=$1 five_reset=$2 seven_pct=$3 seven_reset=$4

  # Skip the write only when the four values are unchanged from disk AND
  # the on-disk fetched_at is still younger than this floor. An
  # unconditional skip (every render re-derives the same stdin values
  # while usage sits flat) would let fetched_at freeze indefinitely,
  # eventually age past resolve_usage_values's 900s read-side staleness
  # bound, and blank the segment even though the numbers were never
  # wrong — the throttle would defeat the cache's whole purpose. The
  # floor keeps the throttle (at most one write per this many seconds
  # while idle) while guaranteeing fetched_at is refreshed well inside
  # the read bound.
  local refresh_floor=300
  if [[ -f "$USAGE_CACHE" ]]; then
    local existing existing_five_pct existing_five_reset existing_seven_pct existing_seven_reset existing_fetched_at
    existing=$(jq -r '[(.five_hour.used_percentage // ""), (.five_hour.resets_at // ""), (.seven_day.used_percentage // ""), (.seven_day.resets_at // ""), (.fetched_at // "")] | map(tostring) | join("\u0001")' "$USAGE_CACHE" 2>/dev/null)
    IFS=$'\x01' read -r existing_five_pct existing_five_reset existing_seven_pct existing_seven_reset existing_fetched_at <<< "$existing"
    if [[ "$existing_five_pct" == "$five_pct" && "$existing_five_reset" == "$five_reset" \
      && "$existing_seven_pct" == "$seven_pct" && "$existing_seven_reset" == "$seven_reset" \
      && "$existing_fetched_at" =~ ^[0-9]+$ ]] \
      && (( $(date +%s) - existing_fetched_at < refresh_floor )); then
      return
    fi
  fi

  # Atomic write: tmp file + mv, not a direct redirect into $USAGE_CACHE
  # — a reader mid-write must never see a partial/truncated cache
  # (safe today only by luck, since a malformed partial write happens to
  # collapse into the anti-fabrication guard — not by design).
  local tmp="${USAGE_CACHE}.tmp.$$"
  jq -n \
    --argjson five_pct "${five_pct:-null}" \
    --argjson five_reset "${five_reset:-null}" \
    --argjson seven_pct "${seven_pct:-null}" \
    --argjson seven_reset "${seven_reset:-null}" \
    --argjson fetched_at "$(date +%s)" \
    '{five_hour: {used_percentage: $five_pct, resets_at: $five_reset},
      seven_day: {used_percentage: $seven_pct, resets_at: $seven_reset},
      fetched_at: $fetched_at}' > "$tmp" 2>/dev/null && mv -f "$tmp" "$USAGE_CACHE"
}

# Renders one window's "label:pct%" segment. reset_epoch drives the
# label (5h -> local hour, 7d -> m/d); falls back to the default label
# (5h/7d) if fmt_epoch can't format it.
render_usage_segment() {
  local default_label=$1 pct_raw=$2 reset_epoch=$3 date_fmt=$4 lowercase=$5
  local pct color label formatted
  pct=$(awk "BEGIN {printf \"%.0f\", $pct_raw}")

  color=$GREEN
  ((pct >= 80)) && color=$RED
  ((pct >= 50 && pct < 80)) && color=$YELLOW

  label=$default_label
  if [[ -n "$reset_epoch" ]]; then
    formatted=$(fmt_epoch "$reset_epoch" "$date_fmt")
    [[ "$lowercase" == "1" ]] && formatted=$(echo "$formatted" | tr '[:upper:]' '[:lower:]')
    [[ -n "$formatted" ]] && label=$formatted
  fi

  printf '%s%s:%s%s%d%%%s' "$DIM" "$label" "$RESET" "$color" "$pct" "$RESET"
}

# Resolves one window: stdin's value when present, the (fresh) cache's
# otherwise. Prints "pct\x01reset\x01came_from_stdin".
resolve_window() {
  local stdin_pct=$1 stdin_reset=$2 cache_pct=$3 cache_reset=$4
  if [[ -n "$stdin_pct" && "$stdin_pct" != "null" ]]; then
    printf '%s%s1' "$stdin_pct" "$stdin_reset"
  else
    printf '%s%s0' "$cache_pct" "$cache_reset"
  fi
}

# Resolves this render's usage values: stdin when present, falling back
# per window to the (900s-fresh) cache otherwise, refreshing the cache
# whenever stdin carried anything. Validates used_percentage before it's
# used further — invalid is treated as ABSENT, never fabricated as 0.
# Prints "five_pct\x01five_reset\x01seven_pct\x01seven_reset".
resolve_usage_values() {
  # A cache under a RUNTIME_DIR we don't own could be attacker-planted —
  # render no usage segment rather than trust its contents this run.
  [[ "$RUNTIME_DIR_SAFE" != "1" ]] && return

  # \x01 (not @tsv's tab) throughout this file's IFS=... read lines, on
  # purpose: bash's `read` classifies tab as "IFS whitespace" no matter
  # what IFS is set to, so it squashes/strips LEADING and consecutive
  # tabs — silently misaligning every field whenever an early field is
  # empty. Routine now that either usage window (or the PR fields) can
  # be legitimately absent. \x01 isn't whitespace, so empty leading/
  # middle fields still read into the right variable.
  local stdin_five_pct stdin_five_reset stdin_seven_pct stdin_seven_reset
  IFS=$'\x01' read -r stdin_five_pct stdin_five_reset stdin_seven_pct stdin_seven_reset < <(
    printf '%s' "$INPUT" | jq -r '[(.rate_limits.five_hour.used_percentage // ""), (.rate_limits.five_hour.resets_at // ""), (.rate_limits.seven_day.used_percentage // ""), (.rate_limits.seven_day.resets_at // "")] | map(tostring) | join("")' 2>/dev/null
  )

  # Cache read, once. Gated on fetched_at explicitly: an old v0.6.x cache
  # used different field names (utilization, ISO resets_at), so this
  # fold comes back empty and reads as absent — never a fabricated
  # 0%. A cache older than 900s is dropped the same way.
  local cache_fetched_at="" cache_five_pct="" cache_five_reset="" cache_seven_pct="" cache_seven_reset=""
  if [[ -f "$USAGE_CACHE" ]]; then
    IFS=$'\x01' read -r cache_fetched_at cache_five_pct cache_five_reset cache_seven_pct cache_seven_reset < <(
      jq -r '[(.fetched_at // ""), (.five_hour.used_percentage // ""), (.five_hour.resets_at // ""), (.seven_day.used_percentage // ""), (.seven_day.resets_at // "")] | map(tostring) | join("")' "$USAGE_CACHE" 2>/dev/null
    )
    local cache_fresh=1
    [[ -z "$cache_fetched_at" || "$cache_fetched_at" == "null" || ! "$cache_fetched_at" =~ ^[0-9]+$ ]] && cache_fresh=0
    ((cache_fresh)) && (( $(date +%s) - cache_fetched_at > 900 )) && cache_fresh=0
    ((cache_fresh)) || { cache_five_pct=""; cache_five_reset=""; cache_seven_pct=""; cache_seven_reset=""; }
  fi

  # Per-window resolution (the C2 fix): a payload carrying only one
  # window must never blank out the other's still-good cached data.
  local five_pct five_reset five_from_stdin seven_pct seven_reset seven_from_stdin
  IFS=$'\x01' read -r five_pct five_reset five_from_stdin < <(resolve_window "$stdin_five_pct" "$stdin_five_reset" "$cache_five_pct" "$cache_five_reset")
  IFS=$'\x01' read -r seven_pct seven_reset seven_from_stdin < <(resolve_window "$stdin_seven_pct" "$stdin_seven_reset" "$cache_seven_pct" "$cache_seven_reset")

  # Validate before this reaches awk/bash arithmetic — invalid is
  # ABSENT, never fabricated as 0. Runs before the cache write so a bad
  # value never persists.
  [[ "$five_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || five_pct=""
  [[ "$seven_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || seven_pct=""

  { ((five_from_stdin)) || ((seven_from_stdin)); } && write_usage_cache "$five_pct" "$five_reset" "$seven_pct" "$seven_reset"

  printf '%s%s%s%s' "$five_pct" "$five_reset" "$seven_pct" "$seven_reset"
}

get_usage_limits() {
  # \x01, not tab — see resolve_usage_values's read for why.
  local five_pct five_reset seven_pct seven_reset
  IFS=$'\x01' read -r five_pct five_reset seven_pct seven_reset < <(resolve_usage_values)

  { [[ -z "$five_pct" || "$five_pct" == "null" ]] && [[ -z "$seven_pct" || "$seven_pct" == "null" ]]; } && return

  [[ "$five_reset" =~ ^[0-9]+$ ]] || five_reset=""
  [[ "$seven_reset" =~ ^[0-9]+$ ]] || seven_reset=""

  # Per-window rollover: each window's resets_at is checked
  # independently (5h rolls far more often than 7d) — an expired window
  # drops its own segment without affecting the other.
  local now seg5="" seg7=""
  now=$(date +%s)

  if [[ -n "$five_pct" && "$five_pct" != "null" ]] \
    && { [[ -z "$five_reset" ]] || (( now <= five_reset )); }; then
    seg5=$(render_usage_segment "5h" "$five_pct" "$five_reset" "+%-I%p" 1)
  fi

  if [[ -n "$seven_pct" && "$seven_pct" != "null" ]] \
    && { [[ -z "$seven_reset" ]] || (( now <= seven_reset )); }; then
    seg7=$(render_usage_segment "7d" "$seven_pct" "$seven_reset" "+%m/%d" 0)
  fi

  local combined="$seg5"
  if [[ -n "$seg7" ]]; then
    [[ -n "$combined" ]] && combined="$combined $seg7" || combined="$seg7"
  fi
  [[ -z "$combined" ]] && return

  printf '%s %s│%s' "$combined" "$DIM" "$RESET"
}

# ─────────────────────────────────────────────────────────────
# Context window
# ─────────────────────────────────────────────────────────────
get_context() {
  # Prefer the pre-calculated used_percentage if available — validated
  # before it reaches progress_bar's bash arithmetic ($((...))); an
  # invalid value (never trust stdin) falls through to the token-count
  # fallback below rather than being handed to arithmetic unvalidated.
  local percent
  percent=$(echo "$INPUT" | jq -r '.context_window.used_percentage // empty')
  if [[ "$percent" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
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
  strip_ctrl "$(basename "$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)")"
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

# Strips C0 control bytes (0x00-0x1f) and DEL (0x7f) from any
# stdin/git-derived string before it's emitted into a terminal escape —
# a raw ESC in a branch name, PR field, or URL could otherwise smuggle
# an arbitrary escape sequence (cursor moves, OSC 52 clipboard writes,
# a forged hyperlink) into the rendered line.
strip_ctrl() {
  printf '%s' "$1" | tr -d '\000-\037\177'
}

# OSC 8 hyperlink: \033]8;;URL\033\\TEXT\033]8;;\033\\
hyperlink() {
  local url text
  url=$(strip_ctrl "$1")
  text=$(strip_ctrl "$2")
  printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$url" "$text"
}

get_branch() {
  local branch
  branch=$(git -C "$CWD" branch --show-current 2>/dev/null || git -C "$CWD" rev-parse --short HEAD 2>/dev/null)
  strip_ctrl "$branch"
}

get_pr_number() {
  # Same rationale as get_usage_limits — skip the PR cache/lock entirely
  # rather than trust or write to a RUNTIME_DIR we don't own.
  [[ "$RUNTIME_DIR_SAFE" != "1" ]] && return
  local repo_name=$1 branch=$2
  local cache="${RUNTIME_DIR}/.claude_pr_cache_${repo_name}_${ACCOUNT_ID}"
  local branch_cache="${RUNTIME_DIR}/.claude_pr_branch_${repo_name}_${ACCOUNT_ID}"

  # Check cache
  if [[ -f "$cache" && -f "$branch_cache" ]]; then
    local cached_branch cache_age
    cached_branch=$(cat "$branch_cache" 2>/dev/null)
    cache_age=$(($(date +%s) - $(file_mtime "$cache" || echo 0)))
    if [[ "$cached_branch" == "$branch" && $cache_age -lt 600 ]]; then
      cat "$cache"
      return
    fi
  fi

  # Fetch PR — skip if another fetch is already in flight
  local lock="${RUNTIME_DIR}/.claude_pr_lock_${repo_name}_${ACCOUNT_ID}"
  # Expire stale locks older than 10 seconds (crash guard)
  if [[ -f "$lock" ]]; then
    local lock_age
    lock_age=$(($(date +%s) - $(file_mtime "$lock" || echo 0)))
    if (( lock_age < 10 )); then
      # Another fetch is in flight — return stale cache rather than pile on
      [[ -f "$cache" ]] && cat "$cache"
      return
    fi
    rm -f "$lock"
  fi

  touch "$lock"
  local pr_num
  pr_num=$(timeout 2 gh pr view --json number -q '.number' 2>/dev/null || true)
  rm -f "$lock"
  if [[ -n "$pr_num" ]]; then
    echo "#$pr_num" > "$cache"
    echo "#$pr_num"
  else
    echo "" > "$cache"
  fi
  echo "$branch" > "$branch_cache"
}

# The one place PR text becomes a clickable link: a URL wraps it via
# hyperlink(), an absent URL falls back to plain text. Both resolve_pr
# paths (stdin, gh) call this instead of each duplicating the branch.
pr_link_for() {
  local url=$1 text=$2
  if [[ -n "$url" && "$url" != "null" ]]; then
    hyperlink "$url" "$text"
  else
    printf '%s' "$text"
  fi
}

# Resolves the PR number + link for this render: stdin first (Claude
# Code already resolved it for the session) via a guard-clause early
# return, falling through to get_pr_number's gh lookup only when stdin
# doesn't carry one. Prints "pr\x01pr_link" (empty/empty when no PR).
resolve_pr() {
  local repo=$1 branch=$2

  # \x01, not tab — see resolve_usage_values's read for why.
  local stdin_pr_number stdin_pr_url
  IFS=$'\x01' read -r stdin_pr_number stdin_pr_url < <(
    echo "$INPUT" | jq -r '[(.pr.number // ""), (.pr.url // "")] | map(tostring) | join("")'
  )
  stdin_pr_number=$(strip_ctrl "$stdin_pr_number")

  if [[ -n "$stdin_pr_number" && "$stdin_pr_number" != "null" ]]; then
    local pr="#${stdin_pr_number}"
    printf '%s\x01%s' "$pr" "$(pr_link_for "$stdin_pr_url" "$pr")"
    return
  fi

  local pr
  pr=$(get_pr_number "$repo" "$branch")
  [[ -z "$pr" ]] && return

  local repo_url url=""
  repo_url=$(get_repo_url)
  [[ -n "$repo_url" ]] && url="${repo_url}/pull/${pr#\#}"
  printf '%s\x01%s' "$pr" "$(pr_link_for "$url" "$pr")"
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
# Cross-profile identity (keychain has one OAuth slot — see
# anthropics/claude-code#20553 — so both profiles can silently
# share the same logged-in account). Since v0.7.0 usage itself no
# longer depends on the keychain (it arrives per-session on stdin), so
# this is purely a "did I also log in as the same account elsewhere"
# signal, not a usage-trust signal.
# ─────────────────────────────────────────────────────────────
profile_uuid_state() {
  local work_dir="$HOME/.claude" personal_dir="$HOME/.claude-personal"
  if [[ ! -d "$work_dir" || ! -d "$personal_dir" ]]; then
    echo "single"
    return
  fi

  local work_uuid personal_uuid
  work_uuid=$(jq -r '.oauthAccount.accountUuid // empty' "$work_dir/.claude.json" 2>/dev/null)
  personal_uuid=$(jq -r '.oauthAccount.accountUuid // empty' "$personal_dir/.claude.json" 2>/dev/null)

  if [[ -z "$work_uuid" || -z "$personal_uuid" ]]; then
    echo "unknown"
  elif [[ "$work_uuid" == "$personal_uuid" ]]; then
    echo "equal"
  else
    echo "differ"
  fi
}

shared_login_marker() {
  local state=$1
  [[ "$state" == "equal" ]] && printf '%s=%s' "$DIM" "$RESET"
}

# ─────────────────────────────────────────────────────────────
# Build output
# ─────────────────────────────────────────────────────────────
build_output() {
  local percent repo branch pr pr_link work_status sync_status
  percent=$(get_context)

  # Show account label if multiple accounts exist
  local acct_prefix=""
  if [[ -n "$ACCOUNT_LABEL" && -d "$HOME/.claude-personal" && -d "$HOME/.claude" ]]; then
    local label_color="$ACCOUNT_COLOR"
    ((ACCOUNT_ASSUMED)) && label_color="$DIM"
    local shared_marker
    shared_marker=$(shared_login_marker "$(profile_uuid_state)")
    acct_prefix=$(printf '%s[%s]%s%s ' "$label_color" "$ACCOUNT_LABEL" "$RESET" "$shared_marker")
  fi

  if is_git_repo; then
    repo=$(get_repo_name)
    branch=$(get_branch)
    # \x01, not tab — see resolve_usage_values's read for why.
    IFS=$'\x01' read -r pr pr_link < <(resolve_pr "$repo" "$branch")

    work_status=$(get_work_status)
    sync_status=$(get_sync_status)

    # Full: [W] bar% usage | repo:branch #PR ↔↑
    printf '%s%s %d%% ' "$acct_prefix" "$(progress_bar "$percent")" "$percent"
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

    printf '%s%s %d%% ' "$acct_prefix" "$(progress_bar "$percent")" "$percent"
    local usage_str
    usage_str=$(get_usage_limits)
    [[ -n "$usage_str" ]] && printf '%s ' "$usage_str"
    printf '%s%s%s' "$CYAN" "$folder" "$RESET"
  fi
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────
build_output
exit 0
