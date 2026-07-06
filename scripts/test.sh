#!/bin/bash
# claudeline test harness
# Runs under an isolated $HOME so real ~/.claude* state is never touched.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUSLINE="$REPO_ROOT/statusline-command.sh"
HOOK="$REPO_ROOT/hooks/show-usage-limits.sh"
INSTALL="$REPO_ROOT/install.sh"

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
for f in "$STATUSLINE" "$HOOK" "$INSTALL"; do
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
assert_eq "detect_account identical in statusline + hook" "$DETECT_SRC" "$HOOK_DETECT_SRC"

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
