#!/bin/bash
# claudeline test harness
# Runs under an isolated $HOME so real ~/.claude* state is never touched.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUSLINE="$REPO_ROOT/statusline-command.sh"
INSTALL="$REPO_ROOT/install.sh"

# RUNTIME_DIR is hardcoded in statusline-command.sh as /tmp/claudeline-$(id -u)
# — no test-only env-var backdoor allowed in production code. Without this
# shim the harness computed that SAME path as the real, live uid, so every
# run raced the user's actual statusline (which writes that directory on
# every prompt) and deleted its cache mid-suite. A PATH-shimmed `id` (same
# idiom already used below for `gh`) makes both this script's own `id -u`
# and every `bash "$STATUSLINE"` subprocess's internal `id -u` resolve to
# one synthetic, run-unique uid, so the harness and the script under test
# land on the same isolated dir — and never on the real one.
IDSHIM_DIR=$(mktemp -d)
CLAUDELINE_TEST_UID="9$$"
cat > "$IDSHIM_DIR/id" << EOF
#!/bin/bash
[[ "\$1" == "-u" ]] && { echo "$CLAUDELINE_TEST_UID"; exit 0; }
exec /usr/bin/id "\$@"
EOF
chmod +x "$IDSHIM_DIR/id"
export PATH="$IDSHIM_DIR:$PATH"

# Same per-user 0700 runtime dir the scripts under test create themselves —
# tests that manually pre-seed/inspect an artifact/lock/cache file (rather
# than going through the real script) need this path to match exactly. The
# shim above guarantees it is the synthetic dir, never the real uid's.
RUNTIME_DIR="/tmp/claudeline-$(id -u)"
mkdir -p "$RUNTIME_DIR" 2>/dev/null
chmod 700 "$RUNTIME_DIR" 2>/dev/null

# Tests below eval individual functions extracted from statusline-command.sh
# (rather than running it as a subprocess) — those functions read
# RUNTIME_DIR_SAFE as a global, which is normally set by the script's own
# verify_runtime_dir prelude. This harness owns RUNTIME_DIR itself
# (created just above, no symlink), so it's genuinely safe; set the flag
# directly since the eval'd functions never run that prelude. Subprocess
# invocations (bash "$STATUSLINE") are unaffected — they run their own
# real prelude against this same, genuinely-owned RUNTIME_DIR and derive
# RUNTIME_DIR_SAFE=1 themselves.
RUNTIME_DIR_SAFE=1

PASS=0
FAIL=0

check() {
  local desc=$1 status=$2
  if [[ "$status" == "0" ]]; then
    printf 'PASS: %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n' "$desc"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    printf 'PASS: %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s (expected %q, got %q)\n' "$desc" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

# Pulls a single function definition (single- or multi-line) out of a
# shell file so it can be sourced in isolation without running the
# rest of the script (which reads stdin / hits the network).
extract_func() {
  local file=$1 func=$2
  awk -v f="$func" '
    $0 ~ "^"f"\\(\\) \\{" {
      print
      if ($0 ~ /}[[:space:]]*$/) { exit }
      p=1
      next
    }
    p { print }
    p && /^}/ { exit }
  ' "$file"
}

# ─────────────────────────────────────────────────────────────
# Check 0: syntax
# ─────────────────────────────────────────────────────────────
for f in "$STATUSLINE" "$INSTALL"; do
  bash -n "$f" 2>/dev/null
  check "syntax: ${f#"$REPO_ROOT"/}" $?
done

# ─────────────────────────────────────────────────────────────
# Isolated $HOME fixture — never touch the real machine's profiles
# ─────────────────────────────────────────────────────────────
TEST_HOME=$(mktemp -d)
cleanup() { rm -rf "$TEST_HOME" "$RUNTIME_DIR" "$IDSHIM_DIR"; }
trap cleanup EXIT
export HOME="$TEST_HOME"
mkdir -p "$HOME/.claude" "$HOME/.claude-personal"

# ─────────────────────────────────────────────────────────────
# Area: unset-vs-empty env detection (detect_account). Sole copy since
# v0.7.0 — no hook/capture script left to keep in sync with.
# ─────────────────────────────────────────────────────────────
DETECT_SRC=$(extract_func "$STATUSLINE" detect_account)
eval "$DETECT_SRC"

unset CLAUDE_CONFIG_DIR
detect_account
assert_eq "unset CLAUDE_CONFIG_DIR -> account=work" "work" "$ACCOUNT_ID"
assert_eq "unset CLAUDE_CONFIG_DIR -> assumed" "1" "$ACCOUNT_ASSUMED"

export CLAUDE_CONFIG_DIR=""
detect_account
assert_eq "empty CLAUDE_CONFIG_DIR -> account=work" "work" "$ACCOUNT_ID"
assert_eq "empty CLAUDE_CONFIG_DIR -> not assumed" "0" "$ACCOUNT_ASSUMED"

export CLAUDE_CONFIG_DIR="/some/other/config/dir"
detect_account
assert_eq "non-personal CLAUDE_CONFIG_DIR -> account=work" "work" "$ACCOUNT_ID"
assert_eq "non-personal CLAUDE_CONFIG_DIR -> not assumed" "0" "$ACCOUNT_ASSUMED"

export CLAUDE_CONFIG_DIR="$HOME/.claude-personal"
detect_account
assert_eq "claude-personal CLAUDE_CONFIG_DIR -> account=personal" "personal" "$ACCOUNT_ID"
assert_eq "claude-personal CLAUDE_CONFIG_DIR -> not assumed" "0" "$ACCOUNT_ASSUMED"

unset CLAUDE_CONFIG_DIR

# ─────────────────────────────────────────────────────────────
# Area: PR-cache 3-file account keying (get_pr_number)
# ─────────────────────────────────────────────────────────────
GET_PR_SRC=$(extract_func "$STATUSLINE" get_pr_number)
eval "$GET_PR_SRC"
file_mtime() { stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null; }

GHSTUB=$(mktemp -d)
cat > "$GHSTUB/gh" <<'EOF'
#!/bin/bash
echo '{"number": 999}'
EOF
chmod +x "$GHSTUB/gh"
export PATH="$GHSTUB:$PATH"

rm -f ${RUNTIME_DIR}/.claude_pr_cache_clltest_* ${RUNTIME_DIR}/.claude_pr_branch_clltest_* ${RUNTIME_DIR}/.claude_pr_lock_clltest_*

ACCOUNT_ID=work
get_pr_number clltest main >/dev/null
[[ -f ${RUNTIME_DIR}/.claude_pr_cache_clltest_work ]]; check "work PR cache file created" $?
[[ -f ${RUNTIME_DIR}/.claude_pr_branch_clltest_work ]]; check "work PR branch-cache file created" $?

ACCOUNT_ID=personal
get_pr_number clltest main >/dev/null
[[ -f ${RUNTIME_DIR}/.claude_pr_cache_clltest_personal ]]; check "personal PR cache file created" $?
[[ -f ${RUNTIME_DIR}/.claude_pr_branch_clltest_personal ]]; check "personal PR branch-cache file created" $?

[[ -f ${RUNTIME_DIR}/.claude_pr_cache_clltest_work && -f ${RUNTIME_DIR}/.claude_pr_cache_clltest_personal ]]
check "work and personal PR caches are distinct files" $?

grep -q 'lock="${RUNTIME_DIR}/.claude_pr_lock_${repo_name}_${ACCOUNT_ID}"' "$STATUSLINE"
check "PR lock file keyed by account" $?

rm -f ${RUNTIME_DIR}/.claude_pr_cache_clltest_* ${RUNTIME_DIR}/.claude_pr_branch_clltest_* ${RUNTIME_DIR}/.claude_pr_lock_clltest_*
rm -rf "$GHSTUB"

# ─────────────────────────────────────────────────────────────
# Area: profile_uuid_state (shared-login equal / differing-uuid)
# ─────────────────────────────────────────────────────────────
PROFILE_STATE_SRC=$(extract_func "$STATUSLINE" profile_uuid_state)
eval "$PROFILE_STATE_SRC"

echo '{"oauthAccount":{"accountUuid":"same-uuid"}}' > "$HOME/.claude/.claude.json"
echo '{"oauthAccount":{"accountUuid":"same-uuid"}}' > "$HOME/.claude-personal/.claude.json"
state=$(profile_uuid_state)
assert_eq "equal accountUuid -> equal" "equal" "$state"

echo '{"oauthAccount":{"accountUuid":"different-uuid"}}' > "$HOME/.claude-personal/.claude.json"
state=$(profile_uuid_state)
assert_eq "differing accountUuid -> differ" "differ" "$state"

rm -f "$HOME/.claude-personal/.claude.json"
state=$(profile_uuid_state)
assert_eq "personal .claude.json missing -> unknown" "unknown" "$state"

rmdir "$HOME/.claude-personal" 2>/dev/null || rm -rf "$HOME/.claude-personal"
state=$(profile_uuid_state)
assert_eq "only one profile dir exists -> single" "single" "$state"

mkdir -p "$HOME/.claude-personal"
echo '{"oauthAccount":{"accountUuid":"same-uuid"}}' > "$HOME/.claude-personal/.claude.json"

# ─────────────────────────────────────────────────────────────
# Area: render markers (shared_login_marker). unverifiable_marker (the
# `?`/`!` markers) is deleted in v0.7.0 — usage now arrives per-session
# on stdin, so there's no fetch-time credential state left to flag.
# ─────────────────────────────────────────────────────────────
DIM=$'\033[2m'
RESET=$'\033[0m'
SLM_SRC=$(extract_func "$STATUSLINE" shared_login_marker)
eval "$SLM_SRC"

marker=$(shared_login_marker "equal")
assert_eq "test_shared_login_marker_fires_on_equal_uuids" "${DIM}=${RESET}" "$marker"

marker=$(shared_login_marker "differ")
assert_eq "differ state -> no shared-login marker" "" "$marker"

# ─────────────────────────────────────────────────────────────
# Area: assumed-account label dims (CLAUDE_CONFIG_DIR unset)
# ─────────────────────────────────────────────────────────────
assumed_out=$(echo '{"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":5}}' | env -u CLAUDE_CONFIG_DIR bash "$STATUSLINE" 2>/dev/null)
printf '%s' "$assumed_out" | grep -qF "${DIM}[W]"
check "test_assumed_account_label_dims: unset CLAUDE_CONFIG_DIR dims [W]" $?

# ─────────────────────────────────────────────────────────────
# Area: usage from stdin + epoch cache schema (v0.7.0 — stdin is the
# sole source of usage; the old OAuth-fetch cache schema, and any `?`/`!`
# marker derived from it, is gone).
# ─────────────────────────────────────────────────────────────
GUL_CACHE="${RUNTIME_DIR}/.claude_usage_limits_work.json"
rm -f "$GUL_CACHE"
NO_RATE_LIMITS_JSON='{"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":5}}'

# test_stdin_usage_rendered_and_cached
GUL_FIVE_EPOCH=$(( $(date +%s) + 3600 ))
GUL_SEVEN_EPOCH=$(( $(date +%s) + 86400 ))
stdin_usage_json=$(jq -n --argjson f "$GUL_FIVE_EPOCH" --argjson s "$GUL_SEVEN_EPOCH" '{
  workspace: {current_dir: "/tmp"},
  context_window: {used_percentage: 5},
  rate_limits: {
    five_hour: {used_percentage: 10, resets_at: $f},
    seven_day: {used_percentage: 16, resets_at: $s}
  }
}')
gul_out=$(printf '%s' "$stdin_usage_json" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$gul_out" | grep -q '10%'
check "test_stdin_usage_rendered_and_cached: 5h renders 10%" $?
echo "$gul_out" | grep -q '16%'
check "test_stdin_usage_rendered_and_cached: 7d renders 16%" $?
[[ -f "$GUL_CACHE" ]]; check "test_stdin_usage_rendered_and_cached: cache written" $?
assert_eq "test_stdin_usage_rendered_and_cached: cache used_percentage" "10" "$(jq -r '.five_hour.used_percentage' "$GUL_CACHE" 2>/dev/null)"
assert_eq "test_stdin_usage_rendered_and_cached: cache resets_at is a raw epoch int" "$GUL_FIVE_EPOCH" "$(jq -r '.five_hour.resets_at' "$GUL_CACHE" 2>/dev/null)"
gul_fetched_at=$(jq -r '.five_hour.fetched_at' "$GUL_CACHE" 2>/dev/null)
[[ -n "$gul_fetched_at" && "$gul_fetched_at" != "null" ]]; check "test_stdin_usage_rendered_and_cached: cache has a per-window fetched_at" $?

# test_stdin_absent_renders_from_fresh_cache — seeds its own fixture
# rather than relying on the cache state the PRECEDING test happens to
# leave behind (that coupling made this test pass/fail for the wrong
# reason if the tests above it were ever reordered or changed).
rm -f "$GUL_CACHE"
GUL_OWN_FIVE_EPOCH=$(( $(date +%s) + 3600 ))
GUL_OWN_SEVEN_EPOCH=$(( $(date +%s) + 86400 ))
jq -n --argjson f "$GUL_OWN_FIVE_EPOCH" --argjson s "$GUL_OWN_SEVEN_EPOCH" --argjson fa "$(date +%s)" \
  '{five_hour:{used_percentage:10,resets_at:$f,fetched_at:$fa},seven_day:{used_percentage:16,resets_at:$s,fetched_at:$fa}}' > "$GUL_CACHE"
gul_out2=$(printf '%s' "$NO_RATE_LIMITS_JSON" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$gul_out2" | grep -q '10%'
check "test_stdin_absent_renders_from_fresh_cache: 5h renders from cache" $?
echo "$gul_out2" | grep -q '16%'
check "test_stdin_absent_renders_from_fresh_cache: 7d renders from cache" $?

# test_stdin_absent_no_cache_no_segment. Checks for the "5h:"/"7d:"
# usage-label pattern specifically (not a blanket %-digit grep), since
# the context-window segment always renders its own percentage and would
# otherwise produce a false failure here.
rm -f "$GUL_CACHE"
gul_out3=$(printf '%s' "$NO_RATE_LIMITS_JSON" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$gul_out3" | grep -Eq '(5h|7d):[0-9]+%'
[[ $? -ne 0 ]]; check "test_stdin_absent_no_cache_no_segment: no usage segment rendered" $?

# test_per_window_rollover_5h_expired_7d_valid
gul_past=$(( $(date +%s) - 3600 ))
gul_future=$(( $(date +%s) + 86400 ))
jq -n --argjson f "$gul_past" --argjson s "$gul_future" --argjson now "$(date +%s)" \
  '{five_hour:{used_percentage:99,resets_at:$f,fetched_at:$now},seven_day:{used_percentage:22,resets_at:$s,fetched_at:$now}}' > "$GUL_CACHE"
gul_out4=$(printf '%s' "$NO_RATE_LIMITS_JSON" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$gul_out4" | grep -q '99%'
[[ $? -ne 0 ]]; check "test_per_window_rollover_5h_expired_7d_valid: expired 5h segment dropped" $?
echo "$gul_out4" | grep -q '22%'
check "test_per_window_rollover_5h_expired_7d_valid: valid 7d segment still renders" $?

# test_old_schema_cache_treated_as_absent — a real v0.6.x cache shape
# (utilization + ISO resets_at + token_source/provenance, no
# used_percentage field at all) must render no segment and never a
# fabricated 0%, even though it still has a real fetched_at.
cat > "$GUL_CACHE" <<EOF
{"five_hour":{"utilization":50,"resets_at":"2026-01-01T00:00:00Z"},"seven_day":{"utilization":33,"resets_at":"2026-01-08T00:00:00Z"},"fetched_at":$(date +%s),"token_source":"file","provenance":"verified_match"}
EOF
gul_out5=$(printf '%s' "$NO_RATE_LIMITS_JSON" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$gul_out5" | grep -q '50%'
[[ $? -ne 0 ]]; check "test_old_schema_cache_treated_as_absent: old-schema cache never renders" $?
echo "$gul_out5" | grep -Eq '(^|[^0-9])0%'
[[ $? -ne 0 ]]; check "test_old_schema_cache_treated_as_absent: never fabricates 0%" $?

# ─────────────────────────────────────────────────────────────
# Area: F — test gaps (legitimate zero, rollover boundary, malformed
# resets_at).
# ─────────────────────────────────────────────────────────────

# test_legitimate_zero_used_percentage_renders_not_blank — 0 must render
# as "0%", never be treated the same as an absent/invalid value.
rm -f "$GUL_CACHE"
zero_json=$(jq -n '{
  workspace: {current_dir: "/tmp"},
  context_window: {used_percentage: 5},
  rate_limits: {five_hour: {used_percentage: 0, resets_at: 9999999999}}
}')
zero_out=$(printf '%s' "$zero_json" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$zero_out" | grep -Eq '(^|[^0-9])0%'
check "test_legitimate_zero_used_percentage_renders_not_blank: 0% renders, not blank" $?
rm -f "$GUL_CACHE"

# test_non_numeric_resets_at_treated_as_no_expiry — a malformed resets_at
# must never reach `((...))` arithmetic (which would abort the script);
# the existing regex guard blanks it, which the rollover check then reads
# as "no expiry" and renders regardless of the current time.
jq -n --argjson fa "$(date +%s)" \
  '{five_hour:{used_percentage:77,resets_at:"not-a-number",fetched_at:$fa},seven_day:{}}' > "$GUL_CACHE"
nonnum_out=$(printf '%s' "$NO_RATE_LIMITS_JSON" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>&1)
nonnum_status=$?
assert_eq "test_non_numeric_resets_at_treated_as_no_expiry: statusline exits 0 (no arithmetic error)" "0" "$nonnum_status"
echo "$nonnum_out" | grep -q '77%'
check "test_non_numeric_resets_at_treated_as_no_expiry: renders despite malformed resets_at" $?
rm -f "$GUL_CACHE"

# test_resets_at_equals_now_boundary_still_renders — the rollover check
# uses `now <= resets_at`, so a window resetting in exactly this second
# must still render (only strictly-past should drop). get_usage_limits
# is exercised in-process (not via a subprocess) so there's no spawn
# delay between capturing "now" and the function's own `date +%s` call;
# retried if a wall-clock second boundary is crossed mid-check, so the
# assertion itself never races.
GUL_FUNC_SRC=$(extract_func "$STATUSLINE" get_usage_limits)
RESOLVE_VALUES_SRC=$(extract_func "$STATUSLINE" resolve_usage_values)
RESOLVE_WINDOW_SRC=$(extract_func "$STATUSLINE" resolve_window)
RENDER_SEG_SRC=$(extract_func "$STATUSLINE" render_usage_segment)
READ_CACHED_WINDOW_SRC=$(extract_func "$STATUSLINE" read_cached_window)
WINDOW_CACHE_FRESH_SRC=$(extract_func "$STATUSLINE" window_cache_fresh)
WRITE_USAGE_WINDOW_SRC=$(extract_func "$STATUSLINE" write_usage_window)
eval "$RENDER_SEG_SRC"
eval "$READ_CACHED_WINDOW_SRC"
eval "$WINDOW_CACHE_FRESH_SRC"
eval "$WRITE_USAGE_WINDOW_SRC"
eval "$RESOLVE_WINDOW_SRC"
eval "$RESOLVE_VALUES_SRC"
eval "$GUL_FUNC_SRC"
ACCOUNT_ID=work
ACCOUNT_ASSUMED=0
USAGE_CACHE="${RUNTIME_DIR}/.claude_usage_limits_work.json"
INPUT='{"workspace":{"current_dir":"/tmp"}}'
boundary_before="" boundary_after="" boundary_out=""
for _ in 1 2 3 4 5; do
  boundary_before=$(date +%s)
  jq -n --argjson f "$boundary_before" --argjson fa "$boundary_before" \
    '{five_hour:{used_percentage:55,resets_at:$f,fetched_at:$fa},seven_day:{}}' > "$USAGE_CACHE"
  boundary_out=$(get_usage_limits)
  boundary_after=$(date +%s)
  [[ "$boundary_before" == "$boundary_after" ]] && break
done
echo "$boundary_out" | grep -q '55%'
check "test_resets_at_equals_now_boundary_still_renders: resets_at==now still renders" $?
rm -f "$USAGE_CACHE"

rm -f "$GUL_CACHE"

# ─────────────────────────────────────────────────────────────
# Area: C1 — cross-profile leak (write guard + read-side recency bound).
# Live-reproduced: an env-less session (ACCOUNT_ASSUMED=1, ACCOUNT_ID
# guessed "work") wrote its own numbers into the shared work cache file;
# a later REAL work session then rendered the guessed numbers
# undimmed. The guess must never reach disk — rendering from stdin is
# unaffected, only the WRITE is gated. Separately, a cache read with no
# age bound could render arbitrarily stale numbers as current.
# ─────────────────────────────────────────────────────────────
rm -f "$GUL_CACHE"
GUL_A_FIVE=$(( $(date +%s) + 3600 ))
GUL_A_SEVEN=$(( $(date +%s) + 86400 ))
stdin_assumed_json=$(jq -n --argjson f "$GUL_A_FIVE" --argjson s "$GUL_A_SEVEN" '{
  workspace: {current_dir: "/tmp"},
  context_window: {used_percentage: 5},
  rate_limits: {
    five_hour: {used_percentage: 77, resets_at: $f},
    seven_day: {used_percentage: 88, resets_at: $s}
  }
}')
gul_a_out=$(printf '%s' "$stdin_assumed_json" | env -u CLAUDE_CONFIG_DIR bash "$STATUSLINE" 2>/dev/null)
[[ ! -f "$GUL_CACHE" ]]; check "test_assumed_account_never_writes_cache: no cache file written on a guessed identity" $?
echo "$gul_a_out" | grep -q '77%'
check "test_assumed_account_never_writes_cache: render still shows 5h numbers from stdin" $?
echo "$gul_a_out" | grep -q '88%'
check "test_assumed_account_never_writes_cache: render still shows 7d numbers from stdin" $?
rm -f "$GUL_CACHE"

# test_stale_cache_beyond_max_age_no_usage_segment
GUL_STALE_FETCHED=$(( $(date +%s) - 1200 ))
GUL_STALE_FIVE=$(( $(date +%s) + 3600 ))
jq -n --argjson f "$GUL_STALE_FIVE" --argjson fa "$GUL_STALE_FETCHED" \
  '{five_hour:{used_percentage:42,resets_at:$f,fetched_at:$fa},seven_day:{used_percentage:33,resets_at:$f,fetched_at:$fa}}' > "$GUL_CACHE"
gul_b_out=$(printf '%s' "$NO_RATE_LIMITS_JSON" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$gul_b_out" | grep -q '42%'
[[ $? -ne 0 ]]; check "test_stale_cache_beyond_max_age_no_usage_segment: 5h segment dropped" $?
echo "$gul_b_out" | grep -q '33%'
[[ $? -ne 0 ]]; check "test_stale_cache_beyond_max_age_no_usage_segment: 7d segment dropped" $?
rm -f "$GUL_CACHE"

# test_fresh_cache_within_max_age_renders
GUL_FRESH_FETCHED=$(( $(date +%s) - 60 ))
GUL_FRESH_FIVE=$(( $(date +%s) + 3600 ))
jq -n --argjson f "$GUL_FRESH_FIVE" --argjson fa "$GUL_FRESH_FETCHED" \
  '{five_hour:{used_percentage:42,resets_at:$f,fetched_at:$fa},seven_day:{used_percentage:33,resets_at:$f,fetched_at:$fa}}' > "$GUL_CACHE"
gul_c_out=$(printf '%s' "$NO_RATE_LIMITS_JSON" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$gul_c_out" | grep -q '42%'
check "test_fresh_cache_within_max_age_renders: 1-minute-old cache still renders" $?
rm -f "$GUL_CACHE"

# ─────────────────────────────────────────────────────────────
# Area: FIX3 — per-window fetched_at (v0.7.0 final re-gate #3). fetched_at
# was a single file-global timestamp for both windows. A window whose
# stdin value keeps churning forces write_usage_cache to fire every
# render, refreshing the SHARED fetched_at — which props up a genuinely
# stale sibling window's freshness forever, since the 900s read bound and
# 300s write floor both keyed off that one shared timestamp. Fix: stamp
# fetched_at INSIDE each window object, only when THAT window is
# (re)written from stdin.
# ─────────────────────────────────────────────────────────────

# (a) exact repro from the re-gate finding: seed seven_day 90% with a
# 600s-old (OLD, file-global) fetched_at, then render three times with
# ONLY five_hour churning on stdin. Under the file-global bug, five_hour's
# churn keeps re-triggering a cache write that refreshes the shared
# fetched_at, so seven_day never ages past the 900s bound and renders
# undimmed forever even though it was never re-verified.
rm -f "$GUL_CACHE"
FIX3_SEVEN_FETCHED=$(( $(date +%s) - 600 ))
FIX3_SEVEN_RESET=$(( $(date +%s) + 86400 ))
jq -n --argjson r "$FIX3_SEVEN_RESET" --argjson fa "$FIX3_SEVEN_FETCHED" \
  '{seven_day:{used_percentage:90,resets_at:$r},fetched_at:$fa}' > "$GUL_CACHE"
fix3a_out=""
for five_pct in 11 12 13; do
  fix3a_json=$(jq -n --argjson p "$five_pct" '{workspace:{current_dir:"/tmp"},context_window:{used_percentage:5},rate_limits:{five_hour:{used_percentage:$p,resets_at:9999999999}}}')
  fix3a_out=$(printf '%s' "$fix3a_json" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
done
echo "$fix3a_out" | grep -q '13%'
check "test_stale_sibling_not_propped_by_live_window: churning five_hour still renders its live value" $?
echo "$fix3a_out" | grep -q '90%'
[[ $? -ne 0 ]]; check "test_stale_sibling_not_propped_by_live_window: stale seven_day (fetched_at 600s old) never renders, not propped up by five_hour's churn" $?
rm -f "$GUL_CACHE"

# (b) each window independently honors its own 900s read bound: five_hour
# fresh (60s old), seven_day stale (901s old) — five_hour renders, seven_day
# doesn't, in the SAME render (no stdin rate_limits at all, pure cache read).
rm -f "$GUL_CACHE"
FIX3B_FIVE_FRESH=$(( $(date +%s) - 60 ))
FIX3B_SEVEN_STALE=$(( $(date +%s) - 901 ))
FIX3B_RESET=$(( $(date +%s) + 86400 ))
jq -n --argjson r "$FIX3B_RESET" --argjson f5 "$FIX3B_FIVE_FRESH" --argjson f7 "$FIX3B_SEVEN_STALE" \
  '{five_hour:{used_percentage:21,resets_at:$r,fetched_at:$f5},seven_day:{used_percentage:95,resets_at:$r,fetched_at:$f7}}' > "$GUL_CACHE"
fix3b_out=$(printf '%s' "$NO_RATE_LIMITS_JSON" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$fix3b_out" | grep -q '21%'
check "test_per_window_900s_read_bound: fresh five_hour (60s old) renders" $?
echo "$fix3b_out" | grep -q '95%'
[[ $? -ne 0 ]]; check "test_per_window_900s_read_bound: stale seven_day (901s old) does not render" $?
rm -f "$GUL_CACHE"

# (c) each window independently honors its own 300s write floor: seed
# five_hour 400s old (past the floor, unchanged value incoming) and
# seven_day 30s old (well under the floor, also unchanged) in the SAME
# cache file. A stdin render carrying BOTH windows with identical values
# must refresh only five_hour's fetched_at, leaving seven_day's untouched.
rm -f "$GUL_CACHE"
FIX3C_FIVE_OLD=$(( $(date +%s) - 400 ))
FIX3C_SEVEN_YOUNG=$(( $(date +%s) - 30 ))
FIX3C_RESET=$(( $(date +%s) + 86400 ))
jq -n --argjson r "$FIX3C_RESET" --argjson f5 "$FIX3C_FIVE_OLD" --argjson f7 "$FIX3C_SEVEN_YOUNG" \
  '{five_hour:{used_percentage:60,resets_at:$r,fetched_at:$f5},seven_day:{used_percentage:70,resets_at:$r,fetched_at:$f7}}' > "$GUL_CACHE"
fix3c_json=$(jq -n --argjson r "$FIX3C_RESET" '{workspace:{current_dir:"/tmp"},context_window:{used_percentage:5},rate_limits:{five_hour:{used_percentage:60,resets_at:$r},seven_day:{used_percentage:70,resets_at:$r}}}')
printf '%s' "$fix3c_json" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" >/dev/null 2>&1
fix3c_five_after=$(jq -r '.five_hour.fetched_at' "$GUL_CACHE" 2>/dev/null)
fix3c_seven_after=$(jq -r '.seven_day.fetched_at' "$GUL_CACHE" 2>/dev/null)
[[ "$fix3c_five_after" != "$FIX3C_FIVE_OLD" ]] && (( $(date +%s) - fix3c_five_after < 5 ))
check "test_per_window_300s_write_floor: five_hour past its floor gets refreshed" $?
assert_eq "test_per_window_300s_write_floor: seven_day within its floor is left untouched" "$FIX3C_SEVEN_YOUNG" "$fix3c_seven_after"
rm -f "$GUL_CACHE"

# (d) a legacy/pre-fix cache (single file-global fetched_at, no per-window
# fetched_at) must render NOTHING — never migrated forward — and gets
# fully replaced by the new per-window schema on the next stdin render.
rm -f "$GUL_CACHE"
FIX3D_LEGACY_FETCHED=$(( $(date +%s) - 60 ))
FIX3D_RESET=$(( $(date +%s) + 86400 ))
jq -n --argjson r "$FIX3D_RESET" --argjson fa "$FIX3D_LEGACY_FETCHED" \
  '{five_hour:{used_percentage:12,resets_at:$r},seven_day:{used_percentage:34,resets_at:$r},fetched_at:$fa}' > "$GUL_CACHE"
fix3d_out1=$(printf '%s' "$NO_RATE_LIMITS_JSON" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$fix3d_out1" | grep -Eq '(5h|7d):[0-9]+%'
[[ $? -ne 0 ]]; check "test_legacy_global_fetched_at_cache_renders_nothing: legacy file-global-fetched_at cache never renders" $?

fix3d_json=$(jq -n --argjson r "$FIX3D_RESET" '{workspace:{current_dir:"/tmp"},context_window:{used_percentage:5},rate_limits:{five_hour:{used_percentage:12,resets_at:$r},seven_day:{used_percentage:34,resets_at:$r}}}')
fix3d_out2=$(printf '%s' "$fix3d_json" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$fix3d_out2" | grep -q '12%'
check "test_legacy_global_fetched_at_cache_renders_nothing: next stdin render supplies both windows and renders" $?
fix3d_five_fetched=$(jq -r '.five_hour.fetched_at' "$GUL_CACHE" 2>/dev/null)
fix3d_seven_fetched=$(jq -r '.seven_day.fetched_at' "$GUL_CACHE" 2>/dev/null)
[[ -n "$fix3d_five_fetched" && "$fix3d_five_fetched" != "null" && -n "$fix3d_seven_fetched" && "$fix3d_seven_fetched" != "null" ]]
check "test_legacy_global_fetched_at_cache_renders_nothing: cache file replaced with new per-window-fetched_at schema" $?
rm -f "$GUL_CACHE"

# ─────────────────────────────────────────────────────────────
# Area: C2 — per-window stdin gating. get_usage_limits previously gated
# the ENTIRE stdin branch on five_hour alone: a payload carrying only
# seven_day (five_hour genuinely absent from that response) rendered
# NOTHING and cached NOTHING — real data silently dropped. Each window
# must be gated independently. Both directions tested since a prior
# review round claimed five-only worked but seven-only broke.
# ─────────────────────────────────────────────────────────────

# test_stdin_five_only_renders_and_caches_five_omits_seven
rm -f "$GUL_CACHE"
GUL_B_FIVE=$(( $(date +%s) + 3600 ))
stdin_five_only_json=$(jq -n --argjson f "$GUL_B_FIVE" '{
  workspace: {current_dir: "/tmp"},
  context_window: {used_percentage: 5},
  rate_limits: {
    five_hour: {used_percentage: 61, resets_at: $f}
  }
}')
gul_five_only_out=$(printf '%s' "$stdin_five_only_json" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$gul_five_only_out" | grep -q '61%'
check "test_stdin_five_only_renders_and_caches_five_omits_seven: 5h window renders" $?
gul_five_only_pct_count=$(echo "$gul_five_only_out" | grep -o '%' | wc -l | tr -d ' ')
assert_eq "test_stdin_five_only_renders_and_caches_five_omits_seven: only context% + 5h% rendered (7d omitted)" "2" "$gul_five_only_pct_count"
assert_eq "test_stdin_five_only_renders_and_caches_five_omits_seven: 5h cached" "61" "$(jq -r '.five_hour.used_percentage' "$GUL_CACHE" 2>/dev/null)"
gul_five_only_cached_seven=$(jq -r '.seven_day.used_percentage' "$GUL_CACHE" 2>/dev/null)
[[ -z "$gul_five_only_cached_seven" || "$gul_five_only_cached_seven" == "null" ]]
check "test_stdin_five_only_renders_and_caches_five_omits_seven: 7d not fabricated in cache" $?
rm -f "$GUL_CACHE"

# test_stdin_seven_only_renders_and_caches_seven_omits_five
rm -f "$GUL_CACHE"
GUL_B_SEVEN=$(( $(date +%s) + 86400 ))
stdin_seven_only_json=$(jq -n --argjson s "$GUL_B_SEVEN" '{
  workspace: {current_dir: "/tmp"},
  context_window: {used_percentage: 5},
  rate_limits: {
    seven_day: {used_percentage: 45, resets_at: $s}
  }
}')
gul_seven_only_out=$(printf '%s' "$stdin_seven_only_json" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$gul_seven_only_out" | grep -q '45%'
check "test_stdin_seven_only_renders_and_caches_seven_omits_five: 7d window renders" $?
gul_seven_only_pct_count=$(echo "$gul_seven_only_out" | grep -o '%' | wc -l | tr -d ' ')
assert_eq "test_stdin_seven_only_renders_and_caches_seven_omits_five: only context% + 7d% rendered (5h omitted)" "2" "$gul_seven_only_pct_count"
assert_eq "test_stdin_seven_only_renders_and_caches_seven_omits_five: 7d cached" "45" "$(jq -r '.seven_day.used_percentage' "$GUL_CACHE" 2>/dev/null)"
gul_seven_only_cached_five=$(jq -r '.five_hour.used_percentage' "$GUL_CACHE" 2>/dev/null)
[[ -z "$gul_seven_only_cached_five" || "$gul_seven_only_cached_five" == "null" ]]
check "test_stdin_seven_only_renders_and_caches_seven_omits_five: 5h not fabricated in cache" $?
rm -f "$GUL_CACHE"

# ─────────────────────────────────────────────────────────────
# Area: security batch — D1 numeric validation, D2 control-byte
# stripping, D3 RUNTIME_DIR permission bits.
# ─────────────────────────────────────────────────────────────

# D1: a non-numeric used_percentage must never reach awk/bash
# arithmetic — treated as absent (never fabricated 0), and must never
# execute. The other, valid window must still render (per-window
# independence from the C2 fix holds even when the sibling window fails
# validation).
rm -f "$GUL_CACHE"
d1_json=$(jq -n '{
  workspace: {current_dir: "/tmp"},
  context_window: {used_percentage: 5},
  rate_limits: {
    five_hour: {used_percentage: "1);system(\"id\")", resets_at: 9999999999},
    seven_day: {used_percentage: 30, resets_at: 9999999999}
  }
}')
d1_out=$(printf '%s' "$d1_json" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>&1)
d1_status=$?
assert_eq "test_malicious_used_percentage_no_execution: statusline exits 0" "0" "$d1_status"
echo "$d1_out" | grep -q '30%'
check "test_malicious_used_percentage_no_execution: valid sibling window (7d) still renders" $?
echo "$d1_out" | grep -qi 'system\|command not found\|syntax error'
[[ $? -ne 0 ]]; check "test_malicious_used_percentage_no_execution: no injected payload text or shell error in output" $?
rm -f "$GUL_CACHE"

# D1: same guard on context_window.used_percentage — falls through to
# the safe token-count fallback rather than handing an unvalidated
# string to progress_bar's bash arithmetic.
d1_ctx_json=$(jq -n '{workspace:{current_dir:"/tmp"}, context_window:{used_percentage:"1);system(\"id\")", context_window_size:200000, current_usage:{input_tokens:1000}}}')
d1_ctx_out=$(printf '%s' "$d1_ctx_json" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>&1)
d1_ctx_status=$?
assert_eq "test_malicious_context_used_percentage_no_execution: statusline exits 0" "0" "$d1_ctx_status"
echo "$d1_ctx_out" | grep -qi 'system\|command not found\|syntax error'
[[ $? -ne 0 ]]; check "test_malicious_context_used_percentage_no_execution: no injected payload text or shell error in output" $?

# FIX1: context_window_size is fed to bash arithmetic ($(( size > 0 ? ... )))
# unvalidated — jq's `// 200000` default only fires on JSON null, not on a
# string, so a string value reaches $(( )) as-is. Array-subscript
# command substitution inside arithmetic evaluation executes under both
# bash 3.2 and 5.2. Marker file proves no execution occurred; percent must
# still render using the 200000 default.
rm -f /tmp/.cll_fix1_marker
d1_size_json=$(jq -n '{workspace:{current_dir:"/tmp"}, context_window:{context_window_size:"x[$(touch /tmp/.cll_fix1_marker)]", current_usage:{input_tokens:1000}}}')
d1_size_out=$(printf '%s' "$d1_size_json" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>&1)
d1_size_status=$?
assert_eq "test_malicious_context_window_size_no_execution: statusline exits 0" "0" "$d1_size_status"
[[ ! -f /tmp/.cll_fix1_marker ]]; check "test_malicious_context_window_size_no_execution: injection payload not executed" $?
echo "$d1_size_out" | grep -q '0%'
check "test_malicious_context_window_size_no_execution: context bar still renders using the 200000 default" $?
rm -f /tmp/.cll_fix1_marker

# D1: legitimate float used_percentage (real payload shape) still
# validates and renders.
d1_float_json=$(jq -n '{
  workspace: {current_dir: "/tmp"},
  context_window: {used_percentage: 5},
  rate_limits: {five_hour: {used_percentage: 14.000000000000002, resets_at: 9999999999}}
}')
d1_float_out=$(printf '%s' "$d1_float_json" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$d1_float_out" | grep -q '14%'
check "test_float_used_percentage_renders: 14.000000000000002 renders as 14%" $?
rm -f "$GUL_CACHE"

# D2: strip_ctrl removes C0 control bytes + DEL, leaving printable text
# intact.
STRIP_CTRL_SRC=$(extract_func "$STATUSLINE" strip_ctrl)
eval "$STRIP_CTRL_SRC"
d2_stripped=$(strip_ctrl $'evil\033[31mBAD')
assert_eq "test_strip_ctrl_removes_esc: ESC byte removed, printable text intact" 'evil[31mBAD' "$d2_stripped"
d2_stripped_del=$(strip_ctrl $'oops\177done')
assert_eq "test_strip_ctrl_removes_del: DEL byte removed" 'oopsdone' "$d2_stripped_del"

# D2: hyperlink() strips embedded ESC from both url and text — total
# ESC count in the rendered link must equal exactly the 4 bytes the
# OSC 8 wrapper itself always emits, never more.
HYPERLINK_SRC=$(extract_func "$STATUSLINE" hyperlink)
eval "$HYPERLINK_SRC"
d2_hl_out=$(hyperlink $'http://evil\033]52;c;PWNED' $'text\033TEXT')
d2_hl_esc_count=$(printf '%s' "$d2_hl_out" | tr -cd '\033' | wc -c | tr -d ' ')
assert_eq "test_hyperlink_strips_embedded_esc: only the 4 OSC8-wrapper ESC bytes remain" "4" "$d2_hl_esc_count"

# D2: a branch name containing ESC (the genuinely attacker-influenceable
# vector — repo/branch strings ultimately come from git, which a
# malicious remote or worktree setup could poison) must never carry a
# raw ESC byte into the rendered line. get_branch() is exercised
# directly against a stubbed `git` so the sanitization is verified
# regardless of whether the installed git build would itself accept
# such a ref name.
GET_BRANCH_SRC=$(extract_func "$STATUSLINE" get_branch)
eval "$GET_BRANCH_SRC"
git() { printf 'evil\033PWNED'; }
CWD=/tmp
d2_branch_out=$(get_branch)
unset -f git
d2_branch_esc_count=$(printf '%s' "$d2_branch_out" | tr -cd '\033' | wc -c | tr -d ' ')
assert_eq "test_get_branch_strips_esc: branch name ESC stripped" "0" "$d2_branch_esc_count"
echo "$d2_branch_out" | grep -q "evilPWNED"
check "test_get_branch_strips_esc: sanitized text still present" $?

# FIX2: the non-git-repo render path's `folder` (basename of stdin's
# workspace.current_dir) was the one strip_ctrl call site missed — a real
# directory (not a stub) since a malicious workspace.current_dir is the
# actual attacker-controlled vector, not something git would need to
# accept as a ref name. ESC count is compared against a same-shape clean
# render (not hardcoded) since acct_prefix/progress_bar's own SGR bytes
# vary with surrounding state.
FIX2_PARENT=$(mktemp -d)
FIX2_EVIL_DIR="$FIX2_PARENT/evil"$'\033'"PWNED"
mkdir -p "$FIX2_EVIL_DIR"
fix2_json=$(jq -n --arg dir "$FIX2_EVIL_DIR" '{workspace:{current_dir:$dir},context_window:{used_percentage:5}}')
fix2_out=$(printf '%s' "$fix2_json" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
fix2_esc_count=$(printf '%s' "$fix2_out" | tr -cd '\033' | wc -c | tr -d ' ')

FIX2_CLEAN_DIR="$FIX2_PARENT/evilPWNED"
mkdir -p "$FIX2_CLEAN_DIR"
fix2_clean_json=$(jq -n --arg dir "$FIX2_CLEAN_DIR" '{workspace:{current_dir:$dir},context_window:{used_percentage:5}}')
fix2_clean_out=$(printf '%s' "$fix2_clean_json" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
fix2_clean_esc_count=$(printf '%s' "$fix2_clean_out" | tr -cd '\033' | wc -c | tr -d ' ')

assert_eq "test_folder_strips_esc: ESC count matches a clean-name render (no leaked ESC)" "$fix2_clean_esc_count" "$fix2_esc_count"
echo "$fix2_out" | grep -q "evilPWNED"
check "test_folder_strips_esc: sanitized folder text still present" $?
rm -rf "$FIX2_PARENT"

# ─────────────────────────────────────────────────────────────
# Area: D3 — RUNTIME_DIR must also be refused when it's group/other
# writable. mkdir -m 700 only applies at CREATE time; an existing dir
# we own but that somehow ended up 0777 (pre-created, race, misconfigured
# umask) must be refused just like the ownership/symlink cases.
# ─────────────────────────────────────────────────────────────
rm -rf "$RUNTIME_DIR"
mkdir -p "$RUNTIME_DIR"
chmod 0777 "$RUNTIME_DIR"
CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" </dev/null >/dev/null 2>/tmp/.cll_perm_stderr
grep -q "refusing to use" /tmp/.cll_perm_stderr
check "test_runtime_dir_group_other_writable_refused: 0777 owned-but-unsafe RUNTIME_DIR refused" $?
rm -f /tmp/.cll_perm_stderr

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

# ─────────────────────────────────────────────────────────────
# Area: PR — stdin-first, gh fallback
# ─────────────────────────────────────────────────────────────
PRSTDIN_DIR=$(mktemp -d)
git -C "$PRSTDIN_DIR" init -q
git -C "$PRSTDIN_DIR" commit -q --allow-empty -m init

GHSTUB2=$(mktemp -d)
GH_CALLED="$GHSTUB2/gh_called"
cat > "$GHSTUB2/gh" <<EOF
#!/bin/bash
touch "$GH_CALLED"
echo '555'
EOF
chmod +x "$GHSTUB2/gh"

prstdin_repo=$(basename "$PRSTDIN_DIR")
rm -f ${RUNTIME_DIR}/.claude_pr_cache_${prstdin_repo}_* ${RUNTIME_DIR}/.claude_pr_branch_${prstdin_repo}_* ${RUNTIME_DIR}/.claude_pr_lock_${prstdin_repo}_*

# test_stdin_pr_used_gh_not_invoked
stdin_pr_json=$(jq -n --arg dir "$PRSTDIN_DIR" '{workspace:{current_dir:$dir},context_window:{used_percentage:5},pr:{number:1,url:"https://github.com/x/y/pull/1"}}')
rm -f "$GH_CALLED"
pr_out=$(printf '%s' "$stdin_pr_json" | PATH="$GHSTUB2:$PATH" CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$pr_out" | grep -q '#1'
check "test_stdin_pr_used_gh_not_invoked: stdin PR number rendered" $?
[[ ! -f "$GH_CALLED" ]]; check "test_stdin_pr_used_gh_not_invoked: gh stub NOT invoked" $?

# test_stdin_pr_absent_gh_fallback_invoked
stdin_nopr_json=$(jq -n --arg dir "$PRSTDIN_DIR" '{workspace:{current_dir:$dir},context_window:{used_percentage:5}}')
rm -f "$GH_CALLED" ${RUNTIME_DIR}/.claude_pr_cache_${prstdin_repo}_* ${RUNTIME_DIR}/.claude_pr_branch_${prstdin_repo}_* ${RUNTIME_DIR}/.claude_pr_lock_${prstdin_repo}_*
pr_out2=$(printf '%s' "$stdin_nopr_json" | PATH="$GHSTUB2:$PATH" CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
[[ -f "$GH_CALLED" ]]; check "test_stdin_pr_absent_gh_fallback_invoked: gh stub WAS invoked" $?
echo "$pr_out2" | grep -q '#555'
check "test_stdin_pr_absent_gh_fallback_invoked: gh fallback PR rendered" $?

rm -f ${RUNTIME_DIR}/.claude_pr_cache_${prstdin_repo}_* ${RUNTIME_DIR}/.claude_pr_branch_${prstdin_repo}_* ${RUNTIME_DIR}/.claude_pr_lock_${prstdin_repo}_*
rm -rf "$GHSTUB2" "$PRSTDIN_DIR"

# ─────────────────────────────────────────────────────────────
# Area: PR-cache never persists under a guessed identity. Mirrors the
# write_usage_window guard above — get_pr_number had no ACCOUNT_ASSUMED
# guard on its cache/branch-cache/lock writes.
# ─────────────────────────────────────────────────────────────
PRASSUMED_DIR=$(mktemp -d)
git -C "$PRASSUMED_DIR" init -q
git -C "$PRASSUMED_DIR" commit -q --allow-empty -m init

GHSTUB3=$(mktemp -d)
GH_CALLED3="$GHSTUB3/gh_called"
cat > "$GHSTUB3/gh" <<EOF
#!/bin/bash
touch "$GH_CALLED3"
echo '777'
EOF
chmod +x "$GHSTUB3/gh"

prassumed_repo=$(basename "$PRASSUMED_DIR")
rm -f ${RUNTIME_DIR}/.claude_pr_cache_${prassumed_repo}_* ${RUNTIME_DIR}/.claude_pr_branch_${prassumed_repo}_* ${RUNTIME_DIR}/.claude_pr_lock_${prassumed_repo}_*

# test_assumed_identity_pr_cache_never_written
nopr_json=$(jq -n --arg dir "$PRASSUMED_DIR" '{workspace:{current_dir:$dir},context_window:{used_percentage:5}}')
rm -f "$GH_CALLED3"
prassumed_out=$(printf '%s' "$nopr_json" | PATH="$GHSTUB3:$PATH" env -u CLAUDE_CONFIG_DIR bash "$STATUSLINE" 2>/dev/null)
[[ ! -f ${RUNTIME_DIR}/.claude_pr_cache_${prassumed_repo}_work ]]
check "test_assumed_identity_pr_cache_never_written: no PR cache file written on a guessed identity" $?
[[ ! -f ${RUNTIME_DIR}/.claude_pr_branch_${prassumed_repo}_work ]]
check "test_assumed_identity_pr_cache_never_written: no PR branch-cache file written on a guessed identity" $?
echo "$prassumed_out" | grep -q '#777'
check "test_assumed_identity_pr_cache_never_written: render still shows the PR from a live gh call" $?

# test_explicit_identity_pr_cache_still_written — regression guard: an
# explicit (non-guessed) identity keeps writing the cache as before.
rm -f ${RUNTIME_DIR}/.claude_pr_cache_${prassumed_repo}_* ${RUNTIME_DIR}/.claude_pr_branch_${prassumed_repo}_* ${RUNTIME_DIR}/.claude_pr_lock_${prassumed_repo}_*
prexplicit_out=$(printf '%s' "$nopr_json" | PATH="$GHSTUB3:$PATH" CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
[[ -f ${RUNTIME_DIR}/.claude_pr_cache_${prassumed_repo}_work ]]
check "test_explicit_identity_pr_cache_still_written: PR cache file written on an explicit identity" $?
echo "$prexplicit_out" | grep -q '#777'
check "test_explicit_identity_pr_cache_still_written: render shows the PR" $?

# test_assumed_identity_stdin_pr_no_cache_no_gh — stdin-carried PR under
# a guessed identity: renders from stdin, gh never spawned, no cache write.
rm -f ${RUNTIME_DIR}/.claude_pr_cache_${prassumed_repo}_* ${RUNTIME_DIR}/.claude_pr_branch_${prassumed_repo}_* "$GH_CALLED3"
stdinpr_assumed_json=$(jq -n --arg dir "$PRASSUMED_DIR" '{workspace:{current_dir:$dir},context_window:{used_percentage:5},pr:{number:42,url:"https://github.com/x/y/pull/42"}}')
prstdinassumed_out=$(printf '%s' "$stdinpr_assumed_json" | PATH="$GHSTUB3:$PATH" env -u CLAUDE_CONFIG_DIR bash "$STATUSLINE" 2>/dev/null)
echo "$prstdinassumed_out" | grep -q '#42'
check "test_assumed_identity_stdin_pr_no_cache_no_gh: stdin PR rendered under a guessed identity" $?
[[ ! -f "$GH_CALLED3" ]]; check "test_assumed_identity_stdin_pr_no_cache_no_gh: gh NOT invoked" $?
[[ ! -f ${RUNTIME_DIR}/.claude_pr_cache_${prassumed_repo}_work ]]
check "test_assumed_identity_stdin_pr_no_cache_no_gh: no PR cache file written" $?

rm -f ${RUNTIME_DIR}/.claude_pr_cache_${prassumed_repo}_* ${RUNTIME_DIR}/.claude_pr_branch_${prassumed_repo}_* ${RUNTIME_DIR}/.claude_pr_lock_${prassumed_repo}_* "$GH_CALLED3"
rm -rf "$GHSTUB3" "$PRASSUMED_DIR"

# ─────────────────────────────────────────────────────────────
# Area: no dead refresh/marker machinery left in statusline-command.sh
# (grep-verify — the full-tree variant that also covers install.sh and
# the deleted hook/capture files lives at the end of this suite).
# ─────────────────────────────────────────────────────────────
grep -Eq 'unverifiable_marker|token_source|parse_iso_utc|USAGE_CACHE_TTL_SECONDS|maybe_refresh_usage_cache|resolve_usage_refresh_hook|USAGE_REFRESH_HOOK|provenance' "$STATUSLINE"
[[ $? -ne 0 ]]; check "test_no_unverifiable_marker_exists: statusline has no dead refresh/marker machinery" $?

# ─────────────────────────────────────────────────────────────
# Area: RUNTIME_DIR (per-user 0700 dir replacing bare /tmp for every
# artifact/lock/cache). Sole copy since v0.7.0 — statusline is the only
# script left that creates it.
# ─────────────────────────────────────────────────────────────
rm -rf "$RUNTIME_DIR"
CLAUDE_CONFIG_DIR="$HOME/.claude-personal" bash "$STATUSLINE" < /dev/null >/dev/null 2>&1
[[ -d "$RUNTIME_DIR" ]]; check "RUNTIME_DIR: statusline creates it" $?
runtime_perms=$(stat -f%Lp "$RUNTIME_DIR" 2>/dev/null || stat -c%a "$RUNTIME_DIR" 2>/dev/null)
assert_eq "RUNTIME_DIR: statusline creates it 0700" "700" "$runtime_perms"

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

# ─────────────────────────────────────────────────────────────
# Area: RUNTIME_DIR ownership/symlink guard (verify_runtime_dir). A
# pre-created-by-another-uid directory, or a symlink swapped in before our
# first mkdir, must be refused loudly (stderr) rather than silently
# trusted for lock/artifact/cache writes.
# ─────────────────────────────────────────────────────────────
# Symlink swap: RUNTIME_DIR replaced by a symlink to a directory we
# genuinely own — still refused, since -L catches the path itself being a
# symlink regardless of what (or who) it resolves to. mkdir -p -m 700
# against an existing symlink-to-a-real-dir is a silent no-op (the path
# "already exists" as far as mkdir -p's stat-following check is
# concerned) — verify_runtime_dir's own -L check is what has to catch it.
rm -rf "$RUNTIME_DIR"
SYMLINK_TARGET=$(mktemp -d)
ln -s "$SYMLINK_TARGET" "$RUNTIME_DIR"

CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" </dev/null >/dev/null 2>/tmp/.cll_symlink_stderr
grep -q "refusing to use" /tmp/.cll_symlink_stderr
check "symlinked RUNTIME_DIR: refused loudly" $?
[[ -L "$RUNTIME_DIR" ]]; check "symlinked RUNTIME_DIR: left untouched (still a symlink, not replaced)" $?
[[ -z "$(ls -A "$SYMLINK_TARGET" 2>/dev/null)" ]]; check "symlinked RUNTIME_DIR: no lock/artifact/cache written into the symlink target" $?
rm -f /tmp/.cll_symlink_stderr

# test_runtime_dir_unsafe_still_renders — the existing symlink test above
# discards stdout entirely; capture it here so an unsafe RUNTIME_DIR is
# proven to degrade gracefully (progress bar + folder still render, no
# usage segment) rather than silently producing a blank/broken line.
UNSAFE_RENDER_DIR=$(mktemp -d)
unsafe_render_json=$(jq -n --arg dir "$UNSAFE_RENDER_DIR" '{workspace:{current_dir:$dir},context_window:{used_percentage:42}}')
unsafe_render_out=$(printf '%s' "$unsafe_render_json" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$unsafe_render_out" | grep -q '42%'
check "test_runtime_dir_unsafe_still_renders: progress bar/context percent still renders" $?
echo "$unsafe_render_out" | grep -qF "$(basename "$UNSAFE_RENDER_DIR")"
check "test_runtime_dir_unsafe_still_renders: folder name still renders" $?
echo "$unsafe_render_out" | grep -Eq '(5h|7d):[0-9]+%'
[[ $? -ne 0 ]]; check "test_runtime_dir_unsafe_still_renders: no usage segment (cache disabled)" $?
rm -rf "$UNSAFE_RENDER_DIR" "$SYMLINK_TARGET"
rm -f "$RUNTIME_DIR"

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

# ─────────────────────────────────────────────────────────────
# Area: profile-aware install target — statusline + usage skill only,
# no hook/capture-script downloads, no hooks.SessionStart wiring.
# ─────────────────────────────────────────────────────────────
CURLSTUB=$(mktemp -d)
CURL_URLS_LOG="$CURLSTUB/urls_log"
cat > "$CURLSTUB/curl" <<CURLEOF
#!/bin/bash
outfile=""
url=""
args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
  if [[ "\${args[i]}" == "-o" ]]; then
    outfile="\${args[i+1]}"
  fi
  [[ "\${args[i]}" == http* ]] && url="\${args[i]}"
done
printf '%s\n' "\$url" >> "$CURL_URLS_LOG"
relpath="\${url#*/claudeline/main/}"
cp "$REPO_ROOT/\$relpath" "\$outfile"
CURLEOF
chmod +x "$CURLSTUB/curl"

INSTALL_TARGET=$(mktemp -d)
PATH="$CURLSTUB:$PATH" CLAUDE_CONFIG_DIR="$INSTALL_TARGET/.claude-personal" bash "$INSTALL" >/dev/null 2>&1

[[ -f "$INSTALL_TARGET/.claude-personal/statusline-command.sh" ]]
check "install.sh writes statusline under CLAUDE_CONFIG_DIR" $?

[[ -f "$INSTALL_TARGET/.claude-personal/skills/usage/SKILL.md" ]]
check "install.sh writes usage skill under CLAUDE_CONFIG_DIR" $?

grep -q "$INSTALL_TARGET/.claude-personal/statusline-command.sh" "$INSTALL_TARGET/.claude-personal/settings.json" 2>/dev/null
check "settings.json statusLine command points at CLAUDE_CONFIG_DIR" $?

jq -e '.hooks' "$INSTALL_TARGET/.claude-personal/settings.json" >/dev/null 2>&1
[[ $? -ne 0 ]]; check "test_install_downloads_only_statusline_and_skill: settings.json has no hooks key" $?

[[ ! -f "$INSTALL_TARGET/.claude-personal/hooks/show-usage-limits.sh" ]]
check "test_install_downloads_only_statusline_and_skill: no hook downloaded" $?

[[ ! -f "$INSTALL_TARGET/.claude-personal/scripts/capture-profile-session.sh" ]]
check "test_install_downloads_only_statusline_and_skill: no capture script downloaded" $?

grep -q "show-usage-limits.sh" "$CURL_URLS_LOG"
[[ $? -ne 0 ]]; check "test_install_downloads_only_statusline_and_skill: hook never curled" $?

grep -q "capture-profile-session.sh" "$CURL_URLS_LOG"
[[ $? -ne 0 ]]; check "test_install_downloads_only_statusline_and_skill: capture script never curled" $?

rm -rf "$CURLSTUB" "$INSTALL_TARGET"

# ─────────────────────────────────────────────────────────────
# Area: C3 — structural constraints (mechanical refactor). Pulled out
# as its own helper pair rather than one-off inline checks since both
# build_output and get_usage_limits/resolve_usage_values are held to
# the same two constraints.
# ─────────────────────────────────────────────────────────────
func_line_count() {
  extract_func "$STATUSLINE" "$1" | wc -l | tr -d ' '
}

# Max indent among the function's OWN body lines (excluding its opening
# and closing brace lines). This file indents 2 spaces/level, so indent
# 2 = the function's direct statements (0 levels of nesting), indent 6 =
# 2 levels of nesting — the ceiling this project's CLAUDE.md sets.
func_max_indent() {
  extract_func "$STATUSLINE" "$1" | sed '1d;$d' | awk '
    /^[[:space:]]*$/ { next }
    { match($0, /^[ ]*/); print RLENGTH }
  ' | sort -n | tail -1
}

bo_lines=$(func_line_count build_output)
[[ "$bo_lines" -le 50 ]]
check "test_build_output_le_50_lines: build_output is <=50 lines (got $bo_lines)" $?

bo_indent=$(func_max_indent build_output)
[[ "$bo_indent" -le 6 ]]
check "test_build_output_le_2_nesting_levels: build_output nests <=2 levels (max indent ${bo_indent:-?} spaces)" $?

gul_lines=$(func_line_count get_usage_limits)
[[ "$gul_lines" -le 50 ]]
check "test_get_usage_limits_le_50_lines: get_usage_limits is <=50 lines (got $gul_lines)" $?

gul_fn_indent=$(func_max_indent get_usage_limits)
[[ "$gul_fn_indent" -le 6 ]]
check "test_get_usage_limits_le_2_nesting_levels: get_usage_limits nests <=2 levels (max indent ${gul_fn_indent:-?} spaces)" $?

ruv_lines=$(func_line_count resolve_usage_values)
[[ -n "$ruv_lines" && "$ruv_lines" -gt 0 && "$ruv_lines" -le 50 ]]
check "test_resolve_usage_values_exists_le_50_lines: resolve_usage_values extracted, <=50 lines (got ${ruv_lines:-0})" $?

ruv_indent=$(func_max_indent resolve_usage_values)
[[ "$ruv_indent" -le 6 ]]
check "test_resolve_usage_values_le_2_nesting_levels: resolve_usage_values nests <=2 levels (max indent ${ruv_indent:-?} spaces)" $?

rp_lines=$(func_line_count resolve_pr)
[[ -n "$rp_lines" && "$rp_lines" -gt 0 && "$rp_lines" -le 50 ]]
check "test_resolve_pr_extracted_le_50_lines: resolve_pr extracted from build_output, <=50 lines (got ${rp_lines:-0})" $?

rp_indent=$(func_max_indent resolve_pr)
[[ "$rp_indent" -le 6 ]]
check "test_resolve_pr_le_2_nesting_levels: resolve_pr nests <=2 levels (max indent ${rp_indent:-?} spaces)" $?

# PR-hyperlink construction written ONCE: exactly one call site builds a
# link, instead of the stdin and gh paths each duplicating the
# "hyperlink if a URL exists, else plain text" branch.
hyperlink_call_sites=$(grep -c 'hyperlink "' "$STATUSLINE")
assert_eq "test_pr_hyperlink_construction_written_once: exactly one hyperlink() call site" "1" "$hyperlink_call_sites"

# .pr.number + .pr.url folded into ONE jq call (the \x01-join idiom this
# file already uses elsewhere), not two separate jq spawns.
pr_jq_spawns=$(grep -c "jq -r '.pr\." "$STATUSLINE")
assert_eq "test_pr_fields_folded_into_one_jq_call: no separate .pr.number/.pr.url jq spawns remain" "0" "$pr_jq_spawns"

# ─────────────────────────────────────────────────────────────
# Area: C3 — write_usage_window skips unchanged writes, writes
# atomically, and stamps ITS OWN fetched_at only (see FIX3 above for the
# cross-window isolation this per-window design exists for).
# ─────────────────────────────────────────────────────────────
READ_CACHED_WINDOW_SRC=$(extract_func "$STATUSLINE" read_cached_window)
WRITE_USAGE_WINDOW_SRC=$(extract_func "$STATUSLINE" write_usage_window)
eval "$READ_CACHED_WINDOW_SRC"
eval "$WRITE_USAGE_WINDOW_SRC"
WUC_CACHE="${RUNTIME_DIR}/.claude_usage_limits_work.json"
rm -f "$WUC_CACHE"
ACCOUNT_ID=work
ACCOUNT_ASSUMED=0
USAGE_CACHE="$WUC_CACHE"

# Seed an initial write, then call again with an IDENTICAL value — the
# window's fetched_at must be left untouched (currently rewrites on every
# render; was <=1/300s before this project's v0.6.x throttle).
write_usage_window five_hour 42 9999999999
wuc_fetched_1=$(jq -r '.five_hour.fetched_at' "$WUC_CACHE" 2>/dev/null)
sleep 1
write_usage_window five_hour 42 9999999999
wuc_fetched_2=$(jq -r '.five_hour.fetched_at' "$WUC_CACHE" 2>/dev/null)
assert_eq "test_write_usage_window_skips_unchanged: fetched_at untouched when the value is identical" "$wuc_fetched_1" "$wuc_fetched_2"
rm -f "$WUC_CACHE"

# test_write_usage_window_refreshes_on_age_floor_when_unchanged — even
# though the value is IDENTICAL to what's on disk, a window whose
# fetched_at is already older than the refresh floor must still be
# rewritten (fetched_at advanced to ~now). Without this, a flat usage
# window would freeze fetched_at forever, it would eventually age past
# resolve_usage_values's 900s read-side staleness bound, and the segment
# would blank out even though the numbers were never wrong.
wuc_old_fetched=$(( $(date +%s) - 400 ))
jq -n --argjson f 9999999999 --argjson fa "$wuc_old_fetched" \
  '{five_hour:{used_percentage:42,resets_at:$f,fetched_at:$fa}}' > "$WUC_CACHE"
write_usage_window five_hour 42 9999999999
wuc_refreshed_fetched=$(jq -r '.five_hour.fetched_at' "$WUC_CACHE" 2>/dev/null)
[[ "$wuc_refreshed_fetched" != "$wuc_old_fetched" ]] && (( $(date +%s) - wuc_refreshed_fetched < 5 ))
check "test_write_usage_window_refreshes_on_age_floor_when_unchanged: unchanged value but stale fetched_at still rewritten" $?
rm -f "$WUC_CACHE"

# A window younger than the refresh floor (10s old, well under it) with
# an unchanged value must still be left untouched — the floor only forces
# a write once the window has actually gone stale-ish, not on every call.
wuc_young_fetched=$(( $(date +%s) - 10 ))
jq -n --argjson f 9999999999 --argjson fa "$wuc_young_fetched" \
  '{five_hour:{used_percentage:42,resets_at:$f,fetched_at:$fa}}' > "$WUC_CACHE"
write_usage_window five_hour 42 9999999999
wuc_young_after=$(jq -r '.five_hour.fetched_at' "$WUC_CACHE" 2>/dev/null)
assert_eq "test_write_usage_window_skips_unchanged_within_refresh_floor: 10s-old unchanged window left untouched" "$wuc_young_fetched" "$wuc_young_after"
rm -f "$WUC_CACHE"

# A genuinely different value must still write through, and the SIBLING
# window (not touched by this call) must be carried forward unchanged.
jq -n --argjson f 9999999999 --argjson fa "$(( $(date +%s) - 10 ))" \
  '{five_hour:{used_percentage:42,resets_at:$f,fetched_at:$fa},seven_day:{used_percentage:30,resets_at:$f,fetched_at:$fa}}' > "$WUC_CACHE"
wuc_seven_before=$(jq -r '.seven_day.fetched_at' "$WUC_CACHE" 2>/dev/null)
sleep 1
write_usage_window five_hour 55 9999999999
wuc_fetched_3=$(jq -r '.five_hour.fetched_at' "$WUC_CACHE" 2>/dev/null)
wuc_five_3=$(jq -r '.five_hour.used_percentage' "$WUC_CACHE" 2>/dev/null)
wuc_seven_after=$(jq -r '.seven_day.fetched_at' "$WUC_CACHE" 2>/dev/null)
[[ "$wuc_fetched_3" != "$wuc_seven_before" ]]
check "test_write_usage_window_writes_through_on_change: fetched_at updates when the value actually changes" $?
assert_eq "test_write_usage_window_writes_through_on_change: new value persisted" "55" "$wuc_five_3"
assert_eq "test_write_usage_window_writes_through_on_change: untouched sibling window's fetched_at carried forward unchanged" "$wuc_seven_before" "$wuc_seven_after"
rm -f "$WUC_CACHE"

# Atomic write: a tmp file + mv, not a direct `> $USAGE_CACHE` redirect
# (safe today only by luck — a malformed partial write happens to
# collapse into the anti-fabrication guard — not by design).
grep -q 'mv ' "$STATUSLINE"
check "test_write_usage_window_atomic: write_usage_window uses tmp file + mv" $?
grep -A30 '^write_usage_window() {' "$STATUSLINE" | grep -qE "jq -n.*> \"?\\\$USAGE_CACHE\"?[[:space:]]*2>/dev/null[[:space:]]*$"
[[ $? -ne 0 ]]; check "test_write_usage_window_atomic: no direct non-atomic redirect into \$USAGE_CACHE" $?

write_usage_window five_hour 20 9999999999
[[ -f "$WUC_CACHE" ]]; check "test_write_usage_window_atomic: cache file exists after write" $?
jq -e . "$WUC_CACHE" >/dev/null 2>&1
check "test_write_usage_window_atomic: cache file is valid, complete JSON (no partial write left behind)" $?
wuc_tmp_leftover=$(find "$RUNTIME_DIR" -maxdepth 1 -name '.claude_usage_limits_work.json.tmp*' 2>/dev/null)
[[ -z "$wuc_tmp_leftover" ]]
check "test_write_usage_window_atomic: no leftover tmp file after write" $?
rm -f "$WUC_CACHE"

# test_stdin_unchanged_values_refresh_fetched_at_end_to_end — proves the
# fix through the whole write-then-read path, not just write_usage_window
# in isolation. Seed a cache with five_hour.fetched_at 400s old and the
# SAME value the stdin payload below also carries; the first render must
# still refresh five_hour's fetched_at despite the value matching (the
# age floor forces it). A second render with NO rate_limits on stdin then
# must still show the usage segment, proving fetched_at was genuinely
# advanced and the 900s read-side bound wasn't tripped.
rm -f "$GUL_CACHE"
GUL_E2E_FIVE=$(( $(date +%s) + 3600 ))
GUL_E2E_OLD_FETCHED=$(( $(date +%s) - 400 ))
jq -n --argjson f "$GUL_E2E_FIVE" --argjson fa "$GUL_E2E_OLD_FETCHED" \
  '{five_hour:{used_percentage:66,resets_at:$f,fetched_at:$fa},seven_day:{}}' > "$GUL_CACHE"
gul_e2e_stdin=$(jq -n --argjson f "$GUL_E2E_FIVE" '{
  workspace: {current_dir: "/tmp"},
  context_window: {used_percentage: 5},
  rate_limits: {five_hour: {used_percentage: 66, resets_at: $f}}
}')
printf '%s' "$gul_e2e_stdin" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" >/dev/null 2>&1
gul_e2e_fetched=$(jq -r '.five_hour.fetched_at' "$GUL_CACHE" 2>/dev/null)
(( $(date +%s) - gul_e2e_fetched < 5 ))
check "test_stdin_unchanged_values_refresh_fetched_at_end_to_end: fetched_at refreshed despite unchanged values" $?

gul_e2e_out2=$(printf '%s' "$NO_RATE_LIMITS_JSON" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$STATUSLINE" 2>/dev/null)
echo "$gul_e2e_out2" | grep -q '66%'
check "test_stdin_unchanged_values_refresh_fetched_at_end_to_end: second render (no stdin rate_limits) still shows usage from refreshed cache" $?
rm -f "$GUL_CACHE"

# ─────────────────────────────────────────────────────────────
# Area: no dead subsystem references anywhere in the tree (full-tree
# grep-verify — the statusline-only variant lives further up).
# ─────────────────────────────────────────────────────────────
grep -rEq 'show-usage-limits|capture-profile-session|USAGE_REFRESH_HOOK|maybe_refresh_usage_cache|parse_iso_utc|token_source|provenance|unverifiable_marker' \
  "$STATUSLINE" "$INSTALL" "$REPO_ROOT/settings-example.json" "$REPO_ROOT/skills/usage/SKILL.md" "$REPO_ROOT/skills/usage/CLAUDE.md" 2>/dev/null
[[ $? -ne 0 ]]; check "grep-verify: no dead credential-subsystem references in the shipped tree" $?

[[ ! -e "$REPO_ROOT/hooks/show-usage-limits.sh" ]]
check "grep-verify: hooks/show-usage-limits.sh deleted" $?

[[ ! -e "$REPO_ROOT/scripts/capture-profile-session.sh" ]]
check "grep-verify: scripts/capture-profile-session.sh deleted" $?

[[ ! -d "$REPO_ROOT/hooks" ]]
check "grep-verify: hooks/ directory removed (nothing left to install into it)" $?

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
echo "─────────────────────────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"
((FAIL > 0)) && exit 1
exit 0
