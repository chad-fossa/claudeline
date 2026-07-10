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

# Every artifact/lock/sentinel this hook writes lives under a per-user,
# 0700 runtime dir instead of bare /tmp — /tmp is world-writable and
# shared across every user on the box, so a bare filename there is
# susceptible to a symlink/pre-creation squat from another user. Created
# here, at this hook's first touch of it, with mkdir -p + an explicit
# chmod 700 (mkdir's mode arg is subject to umask, so the chmod isn't
# redundant). Basenames are unchanged — only the parent directory moved.
# scripts/capture-profile-session.sh inlines this identically (standalone
# script); scripts/test.sh asserts the two copies match.
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
# not the path itself) before trusting anything under RUNTIME_DIR this
# run. scripts/capture-profile-session.sh + statusline-command.sh inline
# this identically; scripts/test.sh asserts all three copies match.
verify_runtime_dir() {
  RUNTIME_DIR_SAFE=1
  if [[ -L "$RUNTIME_DIR" || ! -d "$RUNTIME_DIR" || ! -O "$RUNTIME_DIR" ]]; then
    echo "claudeline: refusing to use ${RUNTIME_DIR} — it isn't a directory we own (pre-created or symlinked by another process); lock/artifact/sentinel/cache writes disabled for this run" >&2
    RUNTIME_DIR_SAFE=0
  fi
}
verify_runtime_dir
readonly RUNTIME_DIR_SAFE

readonly CACHE_FILE="${RUNTIME_DIR}/.claude_usage_limits_${_ACCT_ID}.json"

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
# Guard-clause structure (≤2 nesting levels): each disqualifying
# condition returns/falls through immediately rather than nesting the
# whole rest of the function inside progressively deeper ifs.
get_token() {
  TOKEN=""
  TOKEN_SOURCE="unknown"
  local creds_file="${_CREDS_DIR}/.credentials.json"

  if [[ ! -f "$creds_file" ]]; then
    fetch_token_from_keychain
    return $?
  fi

  local access_token
  access_token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)

  # File present but no usable token (empty file, malformed JSON, or
  # valid JSON missing the field) — distinct from the silent absent-file
  # case above.
  if [[ -z "$access_token" ]]; then
    log_malformed_credentials "$creds_file"
    fetch_token_from_keychain
    return $?
  fi

  resolve_file_credentials "$creds_file" "$access_token"
  return $?
}

# File present but no usable token — one loud diagnostic + artifact
# before get_token falls back to Keychain, since an existing-but-broken
# credentials file is itself worth knowing about (unlike an absent one).
log_malformed_credentials() {
  local creds_file=$1
  echo "${DIM}Usage: ${creds_file} exists but has no usable OAuth token (empty or malformed) — falling back to Keychain${RESET}" >&2
  [[ "$RUNTIME_DIR_SAFE" == "1" ]] && printf '%s malformed_or_empty_credentials\n' "$(date +%s)" > "${RUNTIME_DIR}/.claude_cred_malformed_${ACCOUNT_ID}"
}

# Decides the fate of a present, well-formed file token: still valid,
# needs a refresh, or its refresh token has itself expired. Sets the same
# TOKEN/TOKEN_SOURCE globals get_token does — only ever called from there.
resolve_file_credentials() {
  local creds_file=$1 access_token=$2
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

  # lock_held means a sibling render is already refreshing this same
  # account — that sibling's result stands, so this is a benign silent
  # skip, never a failure: no file-refresh-failed token_source (which
  # would trip handle_refresh_failure's artifact/cache-mutation/`!`).
  if [[ "$REFRESH_FAIL_REASON" == "lock_held" ]]; then
    TOKEN_SOURCE="lock_held"
    return 1
  fi

  TOKEN_SOURCE="file-refresh-failed"
  return 1
}

# The Claude Max OAuth token lives in "Claude Code-credentials" regardless of
# CLAUDE_CONFIG_DIR — keychain isn't isolated per config dir, last /login wins.
# Hashed entries (Claude Code-credentials-{hash}) only hold MCP tokens with
# empty accessToken fields, not the Max claudeAiOauth we need.
# jq can fail on MCP-bloated entries truncated at keychain's output limit, so use grep.
fetch_token_from_keychain() {
  [[ "$OSTYPE" != "darwin"* ]] && return 1

  TOKEN_SOURCE="keychain"
  local creds
  creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1
  TOKEN=$(echo "$creds" | grep -o '"claudeAiOauth":{"accessToken":"[^"]*"' \
    | head -1 \
    | sed 's/"claudeAiOauth":{"accessToken":"//;s/"$//')
}

# Single source for the cred lock path — used by refresh_token_grant AND
# maybe_auto_capture below. scripts/capture-profile-session.sh inlines the
# same three lock functions verbatim (standalone script, can't source this
# file); scripts/test.sh asserts the two copies stay byte-identical.
cred_lock_dir() {
  printf '%s/.claude_cred_lock_%s' "$RUNTIME_DIR" "$ACCOUNT_ID"
}

# Acquires the cred lock, reclaiming a stale lock dir first (age > 120s —
# mirrors this repo's other age-out locks: statusline-command.sh's
# usage-refresh lock (30s, maybe_refresh_usage_cache) and PR-fetch lock
# (10s, get_pr_number)). Arms an EXIT trap so a TERM/INT/internal-error
# death still releases the lock; a true SIGKILL bypasses all traps, so the
# age-based reap above — not this trap — is the real backstop for a hard
# kill. Saves/restores whatever EXIT trap the caller already had (rather
# than a bare `trap - EXIT`) so this doesn't clobber a caller's own
# cleanup trap — verified this matters: a naive `trap - EXIT` silently
# erased a caller's pre-existing trap in testing. Callers release via
# release_cred_lock at their own normal exit points.
acquire_cred_lock() {
  [[ "$RUNTIME_DIR_SAFE" != "1" ]] && return 1
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

# POSTs the refresh grant and parses the response. Sets ACCESS_TOKEN /
# NEW_REFRESH_TOKEN / NEW_EXPIRES_AT on success, or REFRESH_FAIL_REASON /
# REFRESH_FAIL_BODY (error/error_description only — an OAuth error body
# never carries a token, but extracting just these two fields keeps that
# guarantee explicit rather than assumed) on failure. --data @- (body
# piped via stdin) instead of -d "$body": a -d/-H value is visible in
# this process's argv (e.g. to `ps`) for as long as curl runs, and the
# refresh token IS this body.
_post_refresh_grant() {
  local refresh_token=$1 client_id=$2 scopes=$3
  local body response http_code payload
  body=$(jq -n --arg rt "$refresh_token" --arg cid "$client_id" --arg scope "$scopes" \
    '{grant_type: "refresh_token", refresh_token: $rt, client_id: $cid, scope: $scope}')

  # response-splitting idiom (-w appends the status code after a \n, then
  # peel it back off) — kept in sync with scripts/capture-profile-
  # session.sh's verify_capture_identity, the only other curl call site
  # using it.
  response=$(printf '%s' "$body" | curl -s -w '\n%{http_code}' --max-time 5 \
    -X POST "https://platform.claude.com/v1/oauth/token" \
    -H "Content-Type: application/json" \
    --data @- 2>/dev/null)
  http_code="${response##*$'\n'}"
  payload="${response%$'\n'*}"

  if [[ "$http_code" != "200" ]] || ! echo "$payload" | jq -e . >/dev/null 2>&1; then
    REFRESH_FAIL_REASON="http_${http_code:-timeout}"
    REFRESH_FAIL_BODY=$(echo "$payload" | jq -r '[(.error // ""), (.error_description // "")] | join(" ")' 2>/dev/null)
    return 1
  fi

  ACCESS_TOKEN=$(echo "$payload" | jq -r '.access_token // empty')
  NEW_REFRESH_TOKEN=$(echo "$payload" | jq -r '.refresh_token // empty')
  local expires_in
  expires_in=$(echo "$payload" | jq -r '.expires_in // empty')

  if [[ -z "$ACCESS_TOKEN" || -z "$expires_in" ]]; then
    REFRESH_FAIL_REASON="parse_failure"
    REFRESH_FAIL_BODY=$(echo "$payload" | jq -r '[(.error // ""), (.error_description // "")] | join(" ")' 2>/dev/null)
    return 1
  fi

  [[ -z "$NEW_REFRESH_TOKEN" ]] && NEW_REFRESH_TOKEN="$refresh_token"
  local now_ms
  now_ms=$(( $(date +%s) * 1000 ))
  NEW_EXPIRES_AT=$(( now_ms + expires_in * 1000 ))
  return 0
}

# Atomically rewrites creds_file with the new ACCESS_TOKEN/NEW_REFRESH_
# TOKEN/NEW_EXPIRES_AT triple _post_refresh_grant set, then deletes the
# pre-write .bak now that the mv is safely done. umask 077 for the window
# between jq's write and chmod: without it, the tmp file briefly exists
# at the process's default (often world-readable) mode before chmod 600
# catches up — this closes that window instead of narrowing it after the
# fact.
_rotate_creds_file() {
  local creds_file=$1 bak_file=$2
  local tmp_file="${creds_file}.tmp"
  (
    umask 077
    jq --arg at "$ACCESS_TOKEN" --arg rt "$NEW_REFRESH_TOKEN" --argjson exp "$NEW_EXPIRES_AT" \
      '.claudeAiOauth.accessToken = $at | .claudeAiOauth.refreshToken = $rt | .claudeAiOauth.expiresAt = $exp' \
      "$creds_file" > "$tmp_file"
  )
  chmod 600 "$tmp_file"
  mv "$tmp_file" "$creds_file"
  rm -f "$bak_file"
}

# Refresh the file-based OAuth token by POSTing the stored refresh_token
# to Anthropic's OAuth endpoint. Refuses on ACCOUNT_ASSUMED (no writes on
# a guessed identity) and when another refresh is already in flight (see
# acquire_cred_lock — wraps the whole read/POST/write critical section).
# Sets REFRESH_FAIL_REASON on failure. Never falls back to Keychain.
refresh_token_grant() {
  REFRESH_FAIL_REASON=""
  REFRESH_FAIL_BODY=""
  local creds_file="${_CREDS_DIR}/.credentials.json"

  if [[ "$ACCOUNT_ASSUMED" == "1" ]]; then
    REFRESH_FAIL_REASON="account_assumed"
    return 1
  fi

  if ! acquire_cred_lock; then
    REFRESH_FAIL_REASON="lock_held"
    return 1
  fi

  local refresh_token client_id scopes
  refresh_token=$(jq -r '.claudeAiOauth.refreshToken // empty' "$creds_file" 2>/dev/null)
  client_id=$(jq -r '.claudeAiOauth.clientId // "9d1c250a-e61b-44d9-88ed-5944d1962f5e"' "$creds_file" 2>/dev/null)
  scopes=$(jq -r '(.claudeAiOauth.scopes // []) | join(" ")' "$creds_file" 2>/dev/null)

  if [[ -z "$refresh_token" ]]; then
    REFRESH_FAIL_REASON="no_refresh_token"
    release_cred_lock
    return 1
  fi

  # .bak exists only to cover the write-failure window between here and
  # a verified-successful _rotate_creds_file mv — chmod 600 explicitly
  # (cp doesn't guarantee the mode of an existing source survives) since
  # this file holds a live refresh token.
  local bak_file="${creds_file}.bak"
  cp "$creds_file" "$bak_file"
  chmod 600 "$bak_file"

  if ! _post_refresh_grant "$refresh_token" "$client_id" "$scopes"; then
    release_cred_lock
    return 1
  fi

  _rotate_creds_file "$creds_file" "$bak_file"

  release_cred_lock
  return 0
}

# Computes this profile's provenance ONCE, at fetch/cache-write time,
# instead of statusline recomputing it on every render (that render-path
# recomputation — file_provenance_matches, now deleted from
# statusline-command.sh — cost an extra jq spawn plus a second file read
# on every single statusline paint). Same match semantics as that
# function had: this profile's .credentials.json claudeline.
# verified_account_uuid vs this profile's .claude.json accountUuid.
# Returns one of three explicit strings (never exit-code-style 0/1 — that
# inversion was a standing trap in the old file_provenance_matches/prov
# pairing, where 0 meant "match" against every other 0=false convention
# in this codebase):
#   verified_match — verified_account_uuid present and equals profile uuid
#   mismatch       — verified_account_uuid present but differs
#   unverified     — no verified capture yet (missing file/field), or a
#                     pre-existing cache with no provenance field at all
compute_provenance() {
  local creds_file="${_CREDS_DIR}/.credentials.json"
  local claude_json="${_CREDS_DIR}/.claude.json"

  local verified_uuid profile_uuid
  verified_uuid=$(jq -r '.claudeline.verified_account_uuid // empty' "$creds_file" 2>/dev/null)
  profile_uuid=$(jq -r '.oauthAccount.accountUuid // empty' "$claude_json" 2>/dev/null)

  if [[ -z "$verified_uuid" ]]; then
    echo "unverified"
  elif [[ -n "$profile_uuid" && "$verified_uuid" == "$profile_uuid" ]]; then
    echo "verified_match"
  else
    echo "mismatch"
  fi
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
  # substitution does NOT strip that NUL. What actually makes this safe
  # is the anchored `grep -a -o '[0-9]\{14\}Z'`: it pulls out only the
  # bare digits+Z run regardless of what NUL/quote/whitespace surrounds
  # it, so the embedded NUL never has to be handled explicitly — -a just
  # keeps grep from treating the NUL-containing line as binary and
  # refusing to match at all. Verified against a real macOS Keychain
  # entry.
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
# falling back to the work install. install.sh ships
# scripts/capture-profile-session.sh under both install paths, but a
# profile installed before that (or by some other means) can still lack
# it — maybe_auto_capture treats a missing script at the resolved path as
# a loud, non-fatal skip, not an error.
resolve_capture_script() {
  local preferred="${_CREDS_DIR}/scripts/capture-profile-session.sh"
  if [[ -f "$preferred" ]]; then
    echo "$preferred"
  else
    echo "$HOME/.claude/scripts/capture-profile-session.sh"
  fi
}

# Sentinel recording the profileFetchedAt VALUE last attempted, regardless
# of outcome (vetoed, missing-script skip, or an actual capture attempt).
# Without this, an unchanged login that keeps getting vetoed (timing
# window) or skipped (missing script) would re-run read_keychain_mdat_epoch
# plus the identity probe in capture-profile-session.sh on EVERY single
# render until the next real login — a probe-storm. A new login (new
# profileFetchedAt value) doesn't match the sentinel, so it naturally
# re-arms.
auto_capture_sentinel() {
  printf '%s/.claude_cred_capture_attempted_%s' "$RUNTIME_DIR" "$ACCOUNT_ID"
}

record_capture_attempt() {
  printf '%s' "$1" > "$(auto_capture_sentinel)" 2>/dev/null
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
# capture-profile-session.sh itself (verify_capture_identity).
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

  # Probe-storm guard: this exact login has already been attempted
  # (whatever the outcome) — skip the ENTIRE flow below, including the
  # keychain mdat read and the identity probe, without even taking the
  # lock.
  local attempted_value
  [[ -f "$(auto_capture_sentinel)" ]] && attempted_value=$(cat "$(auto_capture_sentinel)" 2>/dev/null)
  [[ "$profile_fetched_at" == "$attempted_value" ]] && return 0

  acquire_cred_lock || return 0
  attempt_auto_capture "$profile_fetched_at" "$claude_json"
  release_cred_lock
  return 0
}

# Runs the mdat-corroboration veto check and, if it passes, invokes the
# capture script — assumes the cred lock is already held by the caller
# (maybe_auto_capture). Every path EXCEPT the actual invoke's exit code 1
# (mdat-read failure, veto, missing script, an invoke that exits 0 or 2)
# calls record_capture_attempt so a repeat render for this same login
# skips entirely via maybe_auto_capture's probe-storm guard above. An
# invoke that exits 1 (transient: e.g. an unreadable Keychain entry) does
# NOT record the attempt, so the next render retries rather than being
# stuck on a transient failure until a brand new login.
# Exit-code contract for capture-profile-session.sh (see that script):
# 0 = captured (verified or unverified) ; 2 = vetoed (identity mismatch —
# sentinel yes, prevents a probe-storm re-verifying the same bad session)
# ; 1 = transient failure (lock held, unreadable Keychain — no sentinel).
attempt_auto_capture() {
  local profile_fetched_at=$1 claude_json=$2
  local window="${CLAUDELINE_CAPTURE_WINDOW_SECS:-30}"
  local mdat_epoch profile_fetched_sec delta
  mdat_epoch=$(read_keychain_mdat_epoch)
  if [[ -z "$mdat_epoch" ]]; then
    record_capture_attempt "$profile_fetched_at"
    return 0
  fi
  profile_fetched_sec=$((profile_fetched_at / 1000))
  delta=$((mdat_epoch - profile_fetched_sec))
  ((delta < 0)) && delta=$((-delta))

  local cap_uuid cap_email
  cap_uuid=$(jq -r '.oauthAccount.accountUuid // "unknown"' "$claude_json" 2>/dev/null)
  cap_email=$(jq -r '.oauthAccount.emailAddress // .oauthAccount.email // "unknown"' "$claude_json" 2>/dev/null)

  if ((delta > window)); then
    local artifact="${RUNTIME_DIR}/.claude_cred_capture_vetoed_${ACCOUNT_ID}"
    printf '%s auto_capture_veto reason=timing_window delta=%ss window=%ss profileFetchedAt=%s mdat=%s uuid=%s email=%s\n' \
      "$(date +%s)" "$delta" "$window" "$profile_fetched_at" "$mdat_epoch" "$cap_uuid" "$cap_email" > "$artifact"
    echo "${DIM}Usage: auto-capture vetoed for ${cap_email} (${cap_uuid}) — keychain/login timing outside ${window}s window (delta=${delta}s)${RESET}" >&2
    record_capture_attempt "$profile_fetched_at"
    return 0
  fi

  local capture_script
  capture_script=$(resolve_capture_script)
  if [[ ! -f "$capture_script" ]]; then
    echo "${DIM}Usage: auto-capture skipped for ${cap_email} (${cap_uuid}) — capture script not found at ${capture_script}${RESET}" >&2
    record_capture_attempt "$profile_fetched_at"
    return 0
  fi

  echo "${DIM}Usage: auto-capturing session for ${cap_email} (${cap_uuid})${RESET}" >&2
  # CLAUDELINE_CRED_LOCK_HELD=1 tells the child we already hold the cred
  # lock (acquired above by our own caller, maybe_auto_capture) — it skips
  # its own acquire/release rather than colliding with ours (the
  # self-deadlock this composition test guards: without the hand-off, the
  # child always finds the lock held by its own parent and exits 1 on
  # every real invocation). Stdout is still suppressed (nothing on it is
  # meant for the render); stderr is NOT redirected — it flows through to
  # this hook's own stderr so a failure is no longer invisible.
  local capture_exit
  CLAUDELINE_PROFILE_FETCHED_AT="$profile_fetched_at" CLAUDE_CONFIG_DIR="$_CREDS_DIR" \
    CLAUDELINE_CRED_LOCK_HELD=1 bash "$capture_script" >/dev/null
  capture_exit=$?
  [[ "$capture_exit" == "0" || "$capture_exit" == "2" ]] && record_capture_attempt "$profile_fetched_at"
}

# Fetch usage limits from API
fetch_usage() {
  local token=$1
  # Bearer header via -H @<600-tmp-file> instead of -H "Authorization:
  # Bearer $token" — a -H value is visible in this process's argv (e.g.
  # to `ps`) for as long as curl runs; a file curl reads isn't. Header
  # file is chmod 600 before curl ever opens it, and removed immediately
  # after curl exits regardless of outcome.
  local header_file
  header_file=$(mktemp)
  chmod 600 "$header_file"
  printf 'Authorization: Bearer %s\n' "$token" > "$header_file"

  curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "User-Agent: claude-code/2.0.32" \
    -H @"$header_file" \
    -H "anthropic-beta: oauth-2025-04-20"

  rm -f "$header_file"
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
# loud artifact, and if a cache already exists, merge token_source into it
# (leaving its numbers untouched) so the render continues on stale data.
# On a cold start (no cache yet) do NOT fabricate one — a
# {token_source:"file-refresh-failed"} cache with no five_hour/seven_day
# data would render "5h:0% 7d:0%" via statusline's `// 0` jq defaults,
# which is a fabricated number, not real usage. The /tmp artifact above
# already records the failure; statusline's get_usage_limits treats a
# missing cache (or one missing fetched_at) as "no usage segment", same
# as today's no-cache-yet behavior.
handle_refresh_failure() {
  local reason="${REFRESH_FAIL_REASON:-unknown}"
  local artifact="${RUNTIME_DIR}/.claude_cred_refresh_failed_${ACCOUNT_ID}"
  # REFRESH_FAIL_BODY (error/error_description only — see
  # refresh_token_grant) is set on an HTTP-failure or parse-failure
  # refresh; other failure reasons (lock_held never reaches here,
  # account_assumed, no_refresh_token, refresh_token_expired) never got a
  # server response to report.
  printf '%s %s\n' "$(date +%s)" "$reason" > "$artifact"
  [[ -n "${REFRESH_FAIL_BODY:-}" ]] && printf '%s\n' "$REFRESH_FAIL_BODY" >> "$artifact"

  if [[ -f "$CACHE_FILE" ]]; then
    local merged
    merged=$(jq '. + {token_source: "file-refresh-failed"}' "$CACHE_FILE" 2>/dev/null)
    [[ -n "$merged" ]] && echo "$merged" > "$CACHE_FILE"
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
    elif [[ "$TOKEN_SOURCE" != "lock_held" ]]; then
      # lock_held: a sibling render already owns this refresh — just
      # return, no message, no artifact. The winner's result stands.
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

  # Write to cache file with timestamp + provenance (computed once here,
  # not per-render — see compute_provenance).
  local cache_data provenance
  provenance=$(compute_provenance)
  cache_data=$(echo "$usage" | jq --arg ts "$(date +%s)" --arg src "$TOKEN_SOURCE" --arg prov "$provenance" \
    '. + {fetched_at: ($ts | tonumber), token_source: $src, provenance: $prov}')
  # This render's numbers still print below either way — only the
  # PERSISTED cache write (read by every later statusline render) is
  # skipped when RUNTIME_DIR isn't ours; see verify_runtime_dir.
  [[ "$RUNTIME_DIR_SAFE" == "1" ]] && echo "$cache_data" > "$CACHE_FILE"

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
