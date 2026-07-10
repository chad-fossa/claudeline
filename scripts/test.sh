#!/bin/bash
# claudeline test harness
# Runs under an isolated $HOME so real ~/.claude* state is never touched.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUSLINE="$REPO_ROOT/statusline-command.sh"
HOOK="$REPO_ROOT/hooks/show-usage-limits.sh"
INSTALL="$REPO_ROOT/install.sh"
CAPTURE="$REPO_ROOT/scripts/capture-profile-session.sh"

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
for f in "$STATUSLINE" "$HOOK" "$INSTALL" "$CAPTURE"; do
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
# Area: unset-vs-empty env detection (detect_account)
# ─────────────────────────────────────────────────────────────
DETECT_SRC=$(extract_func "$STATUSLINE" detect_account)
HOOK_DETECT_SRC=$(extract_func "$HOOK" detect_account)
CAPTURE_DETECT_SRC=$(extract_func "$CAPTURE" detect_account)
assert_eq "detect_account identical in statusline + hook" "$DETECT_SRC" "$HOOK_DETECT_SRC"
assert_eq "detect_account identical in statusline + capture script" "$DETECT_SRC" "$CAPTURE_DETECT_SRC"

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

rm -f /tmp/.claude_pr_cache_clltest_* /tmp/.claude_pr_branch_clltest_* /tmp/.claude_pr_lock_clltest_*

ACCOUNT_ID=work
get_pr_number clltest main >/dev/null
[[ -f /tmp/.claude_pr_cache_clltest_work ]]; check "work PR cache file created" $?
[[ -f /tmp/.claude_pr_branch_clltest_work ]]; check "work PR branch-cache file created" $?

ACCOUNT_ID=personal
get_pr_number clltest main >/dev/null
[[ -f /tmp/.claude_pr_cache_clltest_personal ]]; check "personal PR cache file created" $?
[[ -f /tmp/.claude_pr_branch_clltest_personal ]]; check "personal PR branch-cache file created" $?

[[ -f /tmp/.claude_pr_cache_clltest_work && -f /tmp/.claude_pr_cache_clltest_personal ]]
check "work and personal PR caches are distinct files" $?

grep -q 'lock="/tmp/.claude_pr_lock_${repo_name}_${ACCOUNT_ID}"' "$STATUSLINE"
check "PR lock file keyed by account" $?

rm -f /tmp/.claude_pr_cache_clltest_* /tmp/.claude_pr_branch_clltest_* /tmp/.claude_pr_lock_clltest_*
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
# Area: file-first token + TOKEN_SOURCE (get_token)
# ─────────────────────────────────────────────────────────────
GET_TOKEN_SRC=$(extract_func "$HOOK" get_token)
eval "$GET_TOKEN_SRC"

SECSTUB=$(mktemp -d)
SECURITY_STUB_SENTINEL="$SECSTUB/security_called"
cat > "$SECSTUB/security" <<EOF
#!/bin/bash
touch "$SECURITY_STUB_SENTINEL"
echo '{"claudeAiOauth":{"accessToken":"tok_fake_keychain"}}'
EOF
chmod +x "$SECSTUB/security"
export PATH="$SECSTUB:$PATH"

CREDS_TEST_DIR=$(mktemp -d)
_CREDS_DIR="$CREDS_TEST_DIR"
OSTYPE="darwin24"

future_ms=$(( ($(date +%s) + 3600) * 1000 ))
cat > "$CREDS_TEST_DIR/.credentials.json" <<EOF
{"claudeAiOauth":{"accessToken":"tok_fake_valid","expiresAt":$future_ms,"refreshToken":"rtok_fake","refreshTokenExpiresAt":$((future_ms + 1000000))}}
EOF

rm -f "$SECURITY_STUB_SENTINEL"
get_token
assert_eq "file-first: valid unexpired file returns file token" "tok_fake_valid" "$TOKEN"
assert_eq "file-first: TOKEN_SOURCE=file" "file" "$TOKEN_SOURCE"
[[ ! -f "$SECURITY_STUB_SENTINEL" ]]; check "file-first: valid file -> security stub NOT invoked" $?

rm -f "$CREDS_TEST_DIR/.credentials.json"
rm -f "$SECURITY_STUB_SENTINEL"
get_token
assert_eq "no file (Darwin) -> keychain fallback token" "tok_fake_keychain" "$TOKEN"
assert_eq "no file (Darwin) -> token_source=keychain" "keychain" "$TOKEN_SOURCE"
[[ -f "$SECURITY_STUB_SENTINEL" ]]; check "no file (Darwin) -> security stub WAS invoked" $?

rm -rf "$SECSTUB" "$CREDS_TEST_DIR"
unset _CREDS_DIR SECURITY_STUB_SENTINEL

# ─────────────────────────────────────────────────────────────
# Area: refresh_token_grant (owned OAuth refresh)
# ─────────────────────────────────────────────────────────────
REFRESH_SRC=$(extract_func "$HOOK" refresh_token_grant)
eval "$REFRESH_SRC"

CURLSTUB2=$(mktemp -d)
cat > "$CURLSTUB2/curl" <<'EOF'
#!/bin/bash
url=""
for arg in "$@"; do
  [[ "$arg" == http* ]] && url="$arg"
done
oauth_body="${OAUTH_RESPONSE_BODY:-}"
[[ -z "$oauth_body" ]] && oauth_body='{}'
usage_body="${USAGE_RESPONSE_BODY:-}"
[[ -z "$usage_body" ]] && usage_body='{"five_hour":{"utilization":10},"seven_day":{"utilization":5}}'

if [[ "$url" == *"/v1/oauth/token"* ]]; then
  printf '%s\n%s' "$oauth_body" "${OAUTH_HTTP_CODE:-200}"
elif [[ "$url" == *"/api/oauth/usage"* ]]; then
  printf '%s' "$usage_body"
fi
EOF
chmod +x "$CURLSTUB2/curl"
export PATH="$CURLSTUB2:$PATH"

RCREDS_DIR=$(mktemp -d)
_CREDS_DIR="$RCREDS_DIR"
ACCOUNT_ID="clltest"
ACCOUNT_ASSUMED=0
rmdir "/tmp/.claude_cred_lock_clltest" 2>/dev/null

# 200 with rotation
cat > "$RCREDS_DIR/.credentials.json" <<'EOF'
{"claudeAiOauth":{"accessToken":"tok_fake_old","refreshToken":"rtok_fake_old","expiresAt":1000,"clientId":"custom-client","scopes":["a","b"]},"subscriptionType":"max"}
EOF
export OAUTH_HTTP_CODE=200
export OAUTH_RESPONSE_BODY='{"access_token":"tok_fake_new","refresh_token":"rtok_fake_new","expires_in":3600}'
refresh_token_grant
check "200-rotate: refresh_token_grant succeeds" $?
assert_eq "200-rotate: accessToken rewritten" "tok_fake_new" "$(jq -r '.claudeAiOauth.accessToken' "$RCREDS_DIR/.credentials.json")"
assert_eq "200-rotate: refreshToken rotated" "rtok_fake_new" "$(jq -r '.claudeAiOauth.refreshToken' "$RCREDS_DIR/.credentials.json")"
[[ -f "$RCREDS_DIR/.credentials.json.bak" ]]; check "200-rotate: .bak exists" $?
perms=$(stat -f%Lp "$RCREDS_DIR/.credentials.json" 2>/dev/null || stat -c%a "$RCREDS_DIR/.credentials.json" 2>/dev/null)
assert_eq "200-rotate: perms 600" "600" "$perms"
assert_eq "200-rotate: clientId preserved" "custom-client" "$(jq -r '.claudeAiOauth.clientId' "$RCREDS_DIR/.credentials.json")"
assert_eq "200-rotate: subscriptionType preserved" "max" "$(jq -r '.subscriptionType' "$RCREDS_DIR/.credentials.json")"

# 200 without rotation — response omits refresh_token
cat > "$RCREDS_DIR/.credentials.json" <<'EOF'
{"claudeAiOauth":{"accessToken":"tok_fake_old2","refreshToken":"rtok_fake_keep","expiresAt":1000}}
EOF
rm -f "$RCREDS_DIR/.credentials.json.bak"
export OAUTH_RESPONSE_BODY='{"access_token":"tok_fake_new2","expires_in":3600}'
refresh_token_grant
check "200-no-rotate: refresh_token_grant succeeds" $?
assert_eq "200-no-rotate: old refreshToken preserved when response omits it" "rtok_fake_keep" "$(jq -r '.claudeAiOauth.refreshToken' "$RCREDS_DIR/.credentials.json")"

# 500 — file and .bak stay at pre-refresh content, no keychain fallback
cat > "$RCREDS_DIR/.credentials.json" <<'EOF'
{"claudeAiOauth":{"accessToken":"tok_fake_500","refreshToken":"rtok_fake_500","expiresAt":1000}}
EOF
before_content=$(cat "$RCREDS_DIR/.credentials.json")
rm -f "$RCREDS_DIR/.credentials.json.bak"
export OAUTH_HTTP_CODE=500
export OAUTH_RESPONSE_BODY='{"error":"server_error"}'
refresh_token_grant
result=$?
[[ "$result" != "0" ]]; check "500: refresh_token_grant returns failure" $?
assert_eq "500: file content unchanged" "$before_content" "$(cat "$RCREDS_DIR/.credentials.json")"
assert_eq "500: .bak matches pre-refresh content" "$before_content" "$(cat "$RCREDS_DIR/.credentials.json.bak" 2>/dev/null)"
assert_eq "500: REFRESH_FAIL_REASON set" "http_500" "$REFRESH_FAIL_REASON"

# ACCOUNT_ASSUMED=1 — refuses, no writes on a guessed identity
ACCOUNT_ASSUMED=1
cat > "$RCREDS_DIR/.credentials.json" <<'EOF'
{"claudeAiOauth":{"accessToken":"tok_fake_assumed","refreshToken":"rtok_fake_assumed","expiresAt":1000}}
EOF
before_content=$(cat "$RCREDS_DIR/.credentials.json")
rm -f "$RCREDS_DIR/.credentials.json.bak"
export OAUTH_HTTP_CODE=200
export OAUTH_RESPONSE_BODY='{"access_token":"tok_should_not_write","expires_in":3600}'
refresh_token_grant
result=$?
[[ "$result" != "0" ]]; check "ACCOUNT_ASSUMED=1: refresh_token_grant refuses" $?
[[ ! -f "$RCREDS_DIR/.credentials.json.bak" ]]; check "ACCOUNT_ASSUMED=1: no .bak written" $?
assert_eq "ACCOUNT_ASSUMED=1: file content unchanged" "$before_content" "$(cat "$RCREDS_DIR/.credentials.json")"
assert_eq "ACCOUNT_ASSUMED=1: REFRESH_FAIL_REASON=account_assumed" "account_assumed" "$REFRESH_FAIL_REASON"
ACCOUNT_ASSUMED=0

# Lock respected — a held lock refuses the refresh outright
mkdir -p "/tmp/.claude_cred_lock_clltest"
cat > "$RCREDS_DIR/.credentials.json" <<'EOF'
{"claudeAiOauth":{"accessToken":"tok_fake_locked","refreshToken":"rtok_fake_locked","expiresAt":1000}}
EOF
before_content=$(cat "$RCREDS_DIR/.credentials.json")
refresh_token_grant
result=$?
[[ "$result" != "0" ]]; check "lock held: refresh_token_grant refuses" $?
assert_eq "lock held: file content unchanged" "$before_content" "$(cat "$RCREDS_DIR/.credentials.json")"
rmdir "/tmp/.claude_cred_lock_clltest" 2>/dev/null

unset OAUTH_HTTP_CODE OAUTH_RESPONSE_BODY
rm -rf "$RCREDS_DIR"
unset _CREDS_DIR

# fetch_usage carries a network timeout (skills/usage/SKILL.md calls the
# hook synchronously — an unbounded curl would hang the whole session)
FETCH_USAGE_SRC=$(extract_func "$HOOK" fetch_usage)
echo "$FETCH_USAGE_SRC" | grep -q -- '--max-time 5'
check "fetch_usage uses --max-time 5" $?

# ─────────────────────────────────────────────────────────────
# Area: maybe_auto_capture (Task 8 — "/login is all I do"). Trigger is a
# value-delta on .oauthAccount.profileFetchedAt (never mtime — see
# multi-profile-isolation review), gated by a TWO-SIDED corroboration
# window against the keychain item's mdat (a one-sided window is
# satisfiable by a second profile's concurrent login — the review's
# critical finding).
# ─────────────────────────────────────────────────────────────
MAC_SRC=$(extract_func "$HOOK" maybe_auto_capture)
RKM_SRC=$(extract_func "$HOOK" read_keychain_mdat_epoch)
RCS_SRC=$(extract_func "$HOOK" resolve_capture_script)
[[ -n "$MAC_SRC" ]]; check "maybe_auto_capture is defined" $?
eval "$RKM_SRC"
eval "$RCS_SRC"
eval "$MAC_SRC"

epoch_to_mdat_ts() {
  local epoch=$1
  if [[ "$(uname)" == "Darwin" ]]; then
    TZ=UTC date -j -f "%s" "$epoch" "+%Y%m%d%H%M%SZ" 2>/dev/null
  else
    date -u -d "@$epoch" "+%Y%m%d%H%M%SZ" 2>/dev/null
  fi
}

AUTOSEC=$(mktemp -d)
cat > "$AUTOSEC/security" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  [[ "$arg" == "-w" ]] && { echo '{"claudeAiOauth":{"accessToken":"tok_fake_should_not_be_read"}}'; exit 0; }
done
cat <<MDATEOF
keychain: "/tmp/fake.keychain-db"
version: 512
class: "genp"
attributes:
    0x00000007 <blob>="Claude Code-credentials"
    "acct"<blob>="fakeacct"
    "cdat"<timestamp>="${MDAT_TS}"
    "mdat"<timestamp>="${MDAT_TS}"
MDATEOF
EOF
chmod +x "$AUTOSEC/security"
export PATH="$AUTOSEC:$PATH"

AC_DIR=$(mktemp -d)
_CREDS_DIR="$AC_DIR"
mkdir -p "$_CREDS_DIR/scripts"
ACCOUNT_ID="clltest"
ACCOUNT_ASSUMED=0
OSTYPE="darwin24"
BASE_EPOCH=$(date +%s)
BASE_MS=$((BASE_EPOCH * 1000))

# capture-profile-session.sh stub: sentinel file records invocation
cat > "$_CREDS_DIR/scripts/capture-profile-session.sh" <<'EOF'
#!/bin/bash
touch "$AUTO_CAPTURE_SENTINEL"
EOF
chmod +x "$_CREDS_DIR/scripts/capture-profile-session.sh"
AUTO_CAPTURE_SENTINEL="$AC_DIR/capture_invoked"
export AUTO_CAPTURE_SENTINEL

rmdir "/tmp/.claude_cred_lock_clltest" 2>/dev/null
rm -f "/tmp/.claude_cred_capture_vetoed_clltest"

# Trigger fires: profileFetchedAt differs from captured_login_at, mdat +5s
# (inside default 30s window) -> capture invoked.
echo "{\"oauthAccount\":{\"accountUuid\":\"acct-1\",\"profileFetchedAt\":$BASE_MS}}" > "$_CREDS_DIR/.claude.json"
rm -f "$_CREDS_DIR/.credentials.json"
export MDAT_TS=$(epoch_to_mdat_ts $((BASE_EPOCH + 5)))
rm -f "$AUTO_CAPTURE_SENTINEL"
maybe_auto_capture
[[ -f "$AUTO_CAPTURE_SENTINEL" ]]; check "trigger + mdat+5s (in window): capture invoked" $?

# mdat 90s AFTER stamp -> veto artifact, no capture
export MDAT_TS=$(epoch_to_mdat_ts $((BASE_EPOCH + 90)))
rm -f "$AUTO_CAPTURE_SENTINEL" "/tmp/.claude_cred_capture_vetoed_clltest"
maybe_auto_capture
[[ ! -f "$AUTO_CAPTURE_SENTINEL" ]]; check "mdat +90s (outside window): capture NOT invoked" $?
[[ -f "/tmp/.claude_cred_capture_vetoed_clltest" ]]; check "mdat +90s (outside window): veto artifact created" $?

# mdat 40s BEFORE stamp -> veto too (two-sidedness — the review's fix for
# the one-sided-window defect)
export MDAT_TS=$(epoch_to_mdat_ts $((BASE_EPOCH - 40)))
rm -f "$AUTO_CAPTURE_SENTINEL" "/tmp/.claude_cred_capture_vetoed_clltest"
maybe_auto_capture
[[ ! -f "$AUTO_CAPTURE_SENTINEL" ]]; check "mdat -40s (outside window, two-sided): capture NOT invoked" $?
[[ -f "/tmp/.claude_cred_capture_vetoed_clltest" ]]; check "mdat -40s (outside window, two-sided): veto artifact created" $?

# profileFetchedAt absent -> no auto-capture (unchanged keychain+? behavior)
echo '{"oauthAccount":{"accountUuid":"acct-1"}}' > "$_CREDS_DIR/.claude.json"
export MDAT_TS=$(epoch_to_mdat_ts $((BASE_EPOCH + 5)))
rm -f "$AUTO_CAPTURE_SENTINEL" "/tmp/.claude_cred_capture_vetoed_clltest"
maybe_auto_capture
[[ ! -f "$AUTO_CAPTURE_SENTINEL" ]]; check "profileFetchedAt absent: capture NOT invoked" $?
[[ ! -f "/tmp/.claude_cred_capture_vetoed_clltest" ]]; check "profileFetchedAt absent: no veto artifact (not a veto, just no trigger)" $?

# ACCOUNT_ASSUMED=1 -> refuse outright
echo "{\"oauthAccount\":{\"accountUuid\":\"acct-1\",\"profileFetchedAt\":$BASE_MS}}" > "$_CREDS_DIR/.claude.json"
ACCOUNT_ASSUMED=1
rm -f "$_CREDS_DIR/.credentials.json" "$AUTO_CAPTURE_SENTINEL"
maybe_auto_capture
[[ ! -f "$AUTO_CAPTURE_SENTINEL" ]]; check "ACCOUNT_ASSUMED=1: capture NOT invoked" $?
ACCOUNT_ASSUMED=0

# capture script missing -> loud skip, never fatal (render must proceed)
rm -f "$_CREDS_DIR/scripts/capture-profile-session.sh"
rm -f "$_CREDS_DIR/.credentials.json" "$AUTO_CAPTURE_SENTINEL"
maybe_auto_capture 2>/tmp/.cll_ac_stderr
result=$?
assert_eq "capture script missing: maybe_auto_capture still returns 0 (non-fatal)" "0" "$result"
[[ -s /tmp/.cll_ac_stderr ]]; check "capture script missing: loud stderr" $?
rm -f /tmp/.cll_ac_stderr

unset AUTO_CAPTURE_SENTINEL MDAT_TS
rm -rf "$AC_DIR" "$AUTOSEC"
rm -f "/tmp/.claude_cred_capture_vetoed_clltest"
rmdir "/tmp/.claude_cred_lock_clltest" 2>/dev/null
unset _CREDS_DIR ACCOUNT_ID ACCOUNT_ASSUMED

# ─────────────────────────────────────────────────────────────
# Area: main() file-refresh-failed handling (artifact + cache merge,
# no silent keychain fallback)
# ─────────────────────────────────────────────────────────────
E2E_DIR=$(mktemp -d)
E2E_CREDS_DIR="$E2E_DIR/claude-personal"
mkdir -p "$E2E_CREDS_DIR"

past_ms=$(( ($(date +%s) - 3600) * 1000 ))
cat > "$E2E_CREDS_DIR/.credentials.json" <<EOF
{"claudeAiOauth":{"accessToken":"tok_fake_expired","refreshToken":"rtok_fake_e2e","expiresAt":$past_ms,"refreshTokenExpiresAt":$((past_ms + 999999999))}}
EOF

rm -f "/tmp/.claude_usage_limits_personal.json" "/tmp/.claude_cred_refresh_failed_personal"
rmdir "/tmp/.claude_cred_lock_personal" 2>/dev/null
cat > "/tmp/.claude_usage_limits_personal.json" <<'EOF'
{"five_hour":{"utilization":42},"seven_day":{"utilization":7},"fetched_at":1,"token_source":"file"}
EOF

before_e2e_creds=$(cat "$E2E_CREDS_DIR/.credentials.json")

E2ECURL=$(mktemp -d)
cat > "$E2ECURL/curl" <<'EOF'
#!/bin/bash
url=""
for arg in "$@"; do
  [[ "$arg" == http* ]] && url="$arg"
done
[[ "$url" == *"/v1/oauth/token"* ]] && printf '%s\n%s' '{"error":"server_error"}' "500"
EOF
chmod +x "$E2ECURL/curl"

CLAUDE_CONFIG_DIR="$E2E_CREDS_DIR" PATH="$E2ECURL:$PATH" bash "$HOOK" </dev/null >/dev/null 2>/tmp/.cll_e2e_stderr

assert_eq "500 e2e: credentials file unchanged" "$before_e2e_creds" "$(cat "$E2E_CREDS_DIR/.credentials.json")"
[[ -f "$E2E_CREDS_DIR/.credentials.json.bak" ]]; check "500 e2e: .bak created" $?
[[ -f "/tmp/.claude_cred_refresh_failed_personal" ]]; check "500 e2e: refresh-failed artifact created" $?
assert_eq "500 e2e: cache token_source=file-refresh-failed" "file-refresh-failed" "$(jq -r '.token_source' "/tmp/.claude_usage_limits_personal.json")"
assert_eq "500 e2e: cache numbers untouched" "42" "$(jq -r '.five_hour.utilization' "/tmp/.claude_usage_limits_personal.json")"

rm -rf "$E2E_DIR" "$E2ECURL" "$CURLSTUB2"
rm -f "/tmp/.claude_usage_limits_personal.json" "/tmp/.claude_cred_refresh_failed_personal" /tmp/.cll_e2e_stderr
rmdir "/tmp/.claude_cred_lock_personal" 2>/dev/null

# ─────────────────────────────────────────────────────────────
# Area: capture-profile-session.sh (manual provenance-stamped capture +
# identity verification probe, user-run only — never invoked by hook/
# statusline directly; the hook shells out to this script in Task 8)
# ─────────────────────────────────────────────────────────────
CAP_DIR=$(mktemp -d)
CAPSEC=$(mktemp -d)
cat > "$CAPSEC/security" <<'EOF'
#!/bin/bash
echo '{"claudeAiOauth":{"accessToken":"tok_fake_capture","refreshToken":"rtok_fake_capture","expiresAt":9999999999999,"email":"person@example.com"}}'
EOF
chmod +x "$CAPSEC/security"

# curl stub for the Task 7 identity probe (api/oauth/profile) — keyed on
# PROFILE_HTTP_CODE / PROFILE_RESPONSE_BODY env vars per scenario.
CAPCURL=$(mktemp -d)
cat > "$CAPCURL/curl" <<'EOF'
#!/bin/bash
url=""
for arg in "$@"; do
  [[ "$arg" == http* ]] && url="$arg"
done
[[ "$url" != *"/api/oauth/profile"* ]] && exit 0
body="${PROFILE_RESPONSE_BODY:-}"
code="${PROFILE_HTTP_CODE:-200}"
[[ "$code" == "timeout" ]] && exit 0
printf '%s\n%s' "$body" "$code"
EOF
chmod +x "$CAPCURL/curl"
CAPPATH="$CAPCURL:$CAPSEC:$PATH"

# Happy path: probe 200 + uuid matches -> verified_account_uuid + verified_at
# written, captured_login_at seeded from this profile's profileFetchedAt.
CAP_CONFIG_DIR="$CAP_DIR/claude-personal"
mkdir -p "$CAP_CONFIG_DIR"
echo '{"oauthAccount":{"accountUuid":"profile-uuid-abc","profileFetchedAt":1783657301823}}' > "$CAP_CONFIG_DIR/.claude.json"

export PROFILE_HTTP_CODE=200
export PROFILE_RESPONSE_BODY='{"uuid":"profile-uuid-abc","email":"person@example.com"}'
cap_out=$(CLAUDE_CONFIG_DIR="$CAP_CONFIG_DIR" PATH="$CAPPATH" bash "$CAPTURE" 2>&1)
cap_status=$?
check "capture happy path: exits 0" $cap_status
[[ -f "$CAP_CONFIG_DIR/.credentials.json" ]]; check "capture happy path: file written" $?
assert_eq "capture happy path: captured_for_uuid == profile uuid" "profile-uuid-abc" "$(jq -r '.claudeline.captured_for_uuid' "$CAP_CONFIG_DIR/.credentials.json" 2>/dev/null)"
assert_eq "capture happy path (probe match): verified_account_uuid == profile uuid" "profile-uuid-abc" "$(jq -r '.claudeline.verified_account_uuid' "$CAP_CONFIG_DIR/.credentials.json" 2>/dev/null)"
assert_eq "capture happy path (probe match): captured_login_at seeded from profileFetchedAt" "1783657301823" "$(jq -r '.claudeline.captured_login_at' "$CAP_CONFIG_DIR/.credentials.json" 2>/dev/null)"
[[ -n "$(jq -r '.claudeline.verified_at // empty' "$CAP_CONFIG_DIR/.credentials.json" 2>/dev/null)" ]]; check "capture happy path (probe match): verified_at is set" $?
cap_perms=$(stat -f%Lp "$CAP_CONFIG_DIR/.credentials.json" 2>/dev/null || stat -c%a "$CAP_CONFIG_DIR/.credentials.json" 2>/dev/null)
assert_eq "capture happy path: perms 600" "600" "$cap_perms"
echo "$cap_out" | grep -q "tok_fake_capture"
[[ $? -ne 0 ]]; check "capture happy path: no token value on stdout" $?

# Probe 200 + uuid MISMATCH -> abort, no write, loud stderr with both
# uuids + emails (never tokens), veto artifact.
CAP_CONFIG_DIR3="$CAP_DIR/claude-personal-mismatch"
mkdir -p "$CAP_CONFIG_DIR3"
echo '{"oauthAccount":{"accountUuid":"profile-uuid-abc","profileFetchedAt":1783657301823}}' > "$CAP_CONFIG_DIR3/.claude.json"
rm -f "/tmp/.claude_cred_capture_vetoed_personal"

export PROFILE_HTTP_CODE=200
export PROFILE_RESPONSE_BODY='{"uuid":"other-uuid-xyz","email":"other@example.com"}'
cap_out3=$(CLAUDE_CONFIG_DIR="$CAP_CONFIG_DIR3" PATH="$CAPPATH" bash "$CAPTURE" 2>&1)
cap_status=$?
[[ "$cap_status" != "0" ]]; check "capture probe mismatch: exits 1" $?
[[ ! -f "$CAP_CONFIG_DIR3/.credentials.json" ]]; check "capture probe mismatch: no file written" $?
[[ -f "/tmp/.claude_cred_capture_vetoed_personal" ]]; check "capture probe mismatch: veto artifact created" $?
echo "$cap_out3" | grep -q "profile-uuid-abc"
check "capture probe mismatch: stderr names profile uuid" $?
echo "$cap_out3" | grep -q "other-uuid-xyz"
check "capture probe mismatch: stderr names probed uuid" $?
echo "$cap_out3" | grep -q "other@example.com"
check "capture probe mismatch: stderr names probed email" $?
echo "$cap_out3" | grep -q "tok_fake_capture"
[[ $? -ne 0 ]]; check "capture probe mismatch: no token value on stdout/stderr" $?
rm -f "/tmp/.claude_cred_capture_vetoed_personal"

# Probe timeout/non-200 -> file WRITTEN but usable-unverified (no
# verified_account_uuid/verified_at) -> ? stays per Task 6.
CAP_CONFIG_DIR4="$CAP_DIR/claude-personal-unverified"
mkdir -p "$CAP_CONFIG_DIR4"
echo '{"oauthAccount":{"accountUuid":"profile-uuid-abc","profileFetchedAt":1783657301823}}' > "$CAP_CONFIG_DIR4/.claude.json"

export PROFILE_HTTP_CODE=timeout
export PROFILE_RESPONSE_BODY=''
CLAUDE_CONFIG_DIR="$CAP_CONFIG_DIR4" PATH="$CAPPATH" bash "$CAPTURE" >/dev/null 2>&1
cap_status=$?
check "capture probe timeout: exits 0 (still writes)" $cap_status
[[ -f "$CAP_CONFIG_DIR4/.credentials.json" ]]; check "capture probe timeout: file written" $?
assert_eq "capture probe timeout: captured_for_uuid still set" "profile-uuid-abc" "$(jq -r '.claudeline.captured_for_uuid' "$CAP_CONFIG_DIR4/.credentials.json" 2>/dev/null)"
assert_eq "capture probe timeout: verified_account_uuid absent (unverified)" "" "$(jq -r '.claudeline.verified_account_uuid // empty' "$CAP_CONFIG_DIR4/.credentials.json" 2>/dev/null)"
assert_eq "capture probe timeout: verified_at absent (unverified)" "" "$(jq -r '.claudeline.verified_at // empty' "$CAP_CONFIG_DIR4/.credentials.json" 2>/dev/null)"

CAP_CONFIG_DIR5="$CAP_DIR/claude-personal-unparseable"
mkdir -p "$CAP_CONFIG_DIR5"
echo '{"oauthAccount":{"accountUuid":"profile-uuid-abc","profileFetchedAt":1783657301823}}' > "$CAP_CONFIG_DIR5/.claude.json"

export PROFILE_HTTP_CODE=500
export PROFILE_RESPONSE_BODY='not-json'
CLAUDE_CONFIG_DIR="$CAP_CONFIG_DIR5" PATH="$CAPPATH" bash "$CAPTURE" >/dev/null 2>&1
cap_status=$?
check "capture probe non-200: exits 0 (still writes)" $cap_status
[[ -f "$CAP_CONFIG_DIR5/.credentials.json" ]]; check "capture probe non-200: file written" $?
assert_eq "capture probe non-200: verified_account_uuid absent (unverified)" "" "$(jq -r '.claudeline.verified_account_uuid // empty' "$CAP_CONFIG_DIR5/.credentials.json" 2>/dev/null)"

unset PROFILE_HTTP_CODE PROFILE_RESPONSE_BODY

# Missing uuid -> abort, no file
CAP_CONFIG_DIR2="$CAP_DIR/claude-personal-nouuid"
mkdir -p "$CAP_CONFIG_DIR2"
echo '{}' > "$CAP_CONFIG_DIR2/.claude.json"
CLAUDE_CONFIG_DIR="$CAP_CONFIG_DIR2" PATH="$CAPPATH" bash "$CAPTURE" >/dev/null 2>&1
cap_status=$?
[[ "$cap_status" != "0" ]]; check "capture missing uuid: exits 1" $?
[[ ! -f "$CAP_CONFIG_DIR2/.credentials.json" ]]; check "capture missing uuid: no file written" $?

# ACCOUNT_ASSUMED=1 (CLAUDE_CONFIG_DIR unset) -> refuse, no file
rm -f "$HOME/.claude/.credentials.json"
PATH="$CAPPATH" bash -c "unset CLAUDE_CONFIG_DIR; bash '$CAPTURE'" >/dev/null 2>&1
cap_status=$?
[[ "$cap_status" != "0" ]]; check "capture ACCOUNT_ASSUMED=1: exits 1" $?
[[ ! -f "$HOME/.claude/.credentials.json" ]]; check "capture ACCOUNT_ASSUMED=1: no file written" $?

rm -rf "$CAP_DIR" "$CAPSEC" "$CAPCURL"

# ─────────────────────────────────────────────────────────────
# Area: render markers (shared_login_marker / unverifiable_marker)
# ─────────────────────────────────────────────────────────────
DIM=$'\033[2m'
RESET=$'\033[0m'
SLM_SRC=$(extract_func "$STATUSLINE" shared_login_marker)
UVM_SRC=$(extract_func "$STATUSLINE" unverifiable_marker)
eval "$SLM_SRC"
eval "$UVM_SRC"

marker=$(shared_login_marker "equal")
assert_eq "equal state -> shared-login = marker" "${DIM}=${RESET}" "$marker"

marker=$(shared_login_marker "differ")
assert_eq "differ state -> no shared-login marker" "" "$marker"

OSTYPE="darwin24"
marker=$(unverifiable_marker "differ")
assert_eq "darwin + differ -> ? marker" " ${DIM}?${RESET}" "$marker"

marker=$(unverifiable_marker "equal")
assert_eq "darwin + equal -> no ? marker" "" "$marker"

marker=$(unverifiable_marker "single")
assert_eq "darwin + single -> no ? marker" "" "$marker"

marker=$(unverifiable_marker "unknown")
assert_eq "darwin + unknown -> no ? marker" "" "$marker"

OSTYPE="linux-gnu"
marker=$(unverifiable_marker "differ")
assert_eq "linux + differ -> no ? marker (darwin-only)" "" "$marker"

OSTYPE="darwin24"
RED=$'\033[31m'

# token_source-aware suppression: file+matching provenance suppresses ?,
# file+mismatch keeps it, unknown/keychain behave like v0.5.0, and
# file-refresh-failed always renders ! regardless of state/provenance.
marker=$(unverifiable_marker "differ" "file" "0")
assert_eq "token_source=file + provenance match -> no ? marker" "" "$marker"

marker=$(unverifiable_marker "differ" "file" "1")
assert_eq "token_source=file + provenance mismatch -> ? stays" " ${DIM}?${RESET}" "$marker"

marker=$(unverifiable_marker "differ" "unknown" "1")
assert_eq "token_source=unknown -> ? per v0.5.0" " ${DIM}?${RESET}" "$marker"

marker=$(unverifiable_marker "differ" "keychain" "1")
assert_eq "token_source=keychain -> ? per v0.5.0" " ${DIM}?${RESET}" "$marker"

marker=$(unverifiable_marker "equal" "file-refresh-failed" "1")
assert_eq "token_source=file-refresh-failed -> ! marker" " ${DIM}${RED}!${RESET}" "$marker"

# captured_for_uuid alone (provenance_ok=1, i.e. file_provenance_matches
# returned false because verified_account_uuid is absent) must never
# suppress ? even when token_source=file — this is the hard expert
# condition Task 6 fixes.
marker=$(unverifiable_marker "differ" "file" "1")
assert_eq "token_source=file + captured_for_uuid-only (unverified) -> ? stays, suppression never fires on captured_for_uuid alone" " ${DIM}?${RESET}" "$marker"

# ─────────────────────────────────────────────────────────────
# Area: file_provenance_matches (verified_account_uuid vs profile uuid —
# captured_for_uuid is forensics-only and must NEVER gate this)
# ─────────────────────────────────────────────────────────────
FPM_SRC=$(extract_func "$STATUSLINE" file_provenance_matches)
eval "$FPM_SRC"

FPM_DIR=$(mktemp -d)
FPM_PERSONAL="$FPM_DIR/claude-personal"
mkdir -p "$FPM_PERSONAL"

ACCOUNT_ID="personal"
CLAUDE_CONFIG_DIR="$FPM_PERSONAL"

echo '{"oauthAccount":{"accountUuid":"uuid-match"}}' > "$FPM_PERSONAL/.claude.json"
echo '{"claudeAiOauth":{"accessToken":"tok_fake_fpm"},"claudeline":{"captured_for_uuid":"uuid-match","verified_account_uuid":"uuid-match"}}' > "$FPM_PERSONAL/.credentials.json"
file_provenance_matches
check "file_provenance_matches: matching verified_account_uuid -> true" $?

echo '{"claudeAiOauth":{"accessToken":"tok_fake_fpm"},"claudeline":{"captured_for_uuid":"uuid-match","verified_account_uuid":"uuid-other"}}' > "$FPM_PERSONAL/.credentials.json"
file_provenance_matches
result=$?
[[ "$result" != "0" ]]; check "file_provenance_matches: mismatched verified_account_uuid -> false" $?

echo '{"claudeAiOauth":{"accessToken":"tok_fake_fpm"},"claudeline":{"captured_for_uuid":"uuid-match"}}' > "$FPM_PERSONAL/.credentials.json"
file_provenance_matches
result=$?
[[ "$result" != "0" ]]; check "file_provenance_matches: captured_for_uuid alone (no verified_account_uuid) -> false, never suppresses" $?

echo '{"claudeAiOauth":{"accessToken":"tok_fake_fpm"}}' > "$FPM_PERSONAL/.credentials.json"
file_provenance_matches
result=$?
[[ "$result" != "0" ]]; check "file_provenance_matches: no claudeline block -> false" $?

rm -f "$FPM_PERSONAL/.credentials.json"
file_provenance_matches
result=$?
[[ "$result" != "0" ]]; check "file_provenance_matches: no credentials file -> false" $?

rm -rf "$FPM_DIR"
unset ACCOUNT_ID CLAUDE_CONFIG_DIR

# ─────────────────────────────────────────────────────────────
# Area: profile-aware hook path (resolve_usage_refresh_hook)
# ─────────────────────────────────────────────────────────────
RRH_SRC=$(extract_func "$STATUSLINE" resolve_usage_refresh_hook)
eval "$RRH_SRC"

mkdir -p "$HOME/.claude-personal/hooks" "$HOME/.claude/hooks"
cat > "$HOME/.claude/hooks/show-usage-limits.sh" <<'EOF'
#!/bin/bash
EOF
chmod +x "$HOME/.claude/hooks/show-usage-limits.sh"

export CLAUDE_CONFIG_DIR="$HOME/.claude-personal"
cat > "$HOME/.claude-personal/hooks/show-usage-limits.sh" <<'EOF'
#!/bin/bash
EOF
chmod +x "$HOME/.claude-personal/hooks/show-usage-limits.sh"
result=$(resolve_usage_refresh_hook)
assert_eq "executable personal hook preferred" "$HOME/.claude-personal/hooks/show-usage-limits.sh" "$result"

rm -f "$HOME/.claude-personal/hooks/show-usage-limits.sh"
result=$(resolve_usage_refresh_hook)
assert_eq "falls back to work hook when personal missing" "$HOME/.claude/hooks/show-usage-limits.sh" "$result"

unset CLAUDE_CONFIG_DIR
result=$(resolve_usage_refresh_hook)
assert_eq "work hook chosen with CLAUDE_CONFIG_DIR unset" "$HOME/.claude/hooks/show-usage-limits.sh" "$result"

# ─────────────────────────────────────────────────────────────
# Area: profile-aware install target
# ─────────────────────────────────────────────────────────────
CURLSTUB=$(mktemp -d)
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
relpath="\${url#*/claudeline/main/}"
cp "$REPO_ROOT/\$relpath" "\$outfile"
CURLEOF
chmod +x "$CURLSTUB/curl"

INSTALL_TARGET=$(mktemp -d)
PATH="$CURLSTUB:$PATH" CLAUDE_CONFIG_DIR="$INSTALL_TARGET/.claude-personal" bash "$INSTALL" >/dev/null 2>&1

[[ -f "$INSTALL_TARGET/.claude-personal/statusline-command.sh" ]]
check "install.sh writes statusline under CLAUDE_CONFIG_DIR" $?

[[ -x "$INSTALL_TARGET/.claude-personal/hooks/show-usage-limits.sh" ]]
check "install.sh writes hook under CLAUDE_CONFIG_DIR" $?

grep -q "$INSTALL_TARGET/.claude-personal/statusline-command.sh" "$INSTALL_TARGET/.claude-personal/settings.json" 2>/dev/null
check "settings.json statusLine command points at CLAUDE_CONFIG_DIR" $?

grep -q "$INSTALL_TARGET/.claude-personal/hooks/show-usage-limits.sh" "$INSTALL_TARGET/.claude-personal/settings.json" 2>/dev/null
check "settings.json hook command points at CLAUDE_CONFIG_DIR" $?

rm -rf "$CURLSTUB" "$INSTALL_TARGET"

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
echo "─────────────────────────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"
((FAIL > 0)) && exit 1
exit 0
