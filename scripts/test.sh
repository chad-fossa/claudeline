#!/bin/bash
# claudeline test harness
# Runs under an isolated $HOME so real ~/.claude* state is never touched.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUSLINE="$REPO_ROOT/statusline-command.sh"
INSTALL="$REPO_ROOT/install.sh"

# Same per-user 0700 runtime dir the scripts under test create themselves —
# tests that manually pre-seed/inspect an artifact/lock/cache file (rather
# than going through the real script) need this path to match exactly.
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
cleanup() { rm -rf "$TEST_HOME"; }
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
gul_fetched_at=$(jq -r '.fetched_at' "$GUL_CACHE" 2>/dev/null)
[[ -n "$gul_fetched_at" && "$gul_fetched_at" != "null" ]]; check "test_stdin_usage_rendered_and_cached: cache has fetched_at" $?

# test_stdin_absent_renders_from_fresh_cache
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
  '{five_hour:{used_percentage:99,resets_at:$f},seven_day:{used_percentage:22,resets_at:$s},fetched_at:$now}' > "$GUL_CACHE"
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

rm -f "$GUL_CACHE"

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
rm -rf "$SYMLINK_TARGET"
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
