#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="${1:-./claude-switch.sh}"

fail() {
    echo "Error: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    if [[ "$expected" != "$actual" ]]; then
        fail "$message (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        fail "$message (missing '$needle')"
    fi
}

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"
LINUX_BIN_DIR="$TMP_ROOT/linux-bin"
mkdir -p "$LINUX_BIN_DIR"

cat > "$BIN_DIR/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${CLAUDE_STUB_LOG_DIR:?}"
mkdir -p "$CLAUDE_STUB_LOG_DIR"

printf '%s\n' "${CLAUDE_CONFIG_DIR:-}" > "$CLAUDE_STUB_LOG_DIR/config_dir"
printf '%s\n' "$@" > "$CLAUDE_STUB_LOG_DIR/args"

if [[ -n "${CLAUDE_STUB_WRITE_EMAIL:-}" ]]; then
    mkdir -p "${CLAUDE_CONFIG_DIR:?}"
    cat > "${CLAUDE_CONFIG_DIR}/.claude.json" <<JSON
{"oauthAccount":{"emailAddress":"${CLAUDE_STUB_WRITE_EMAIL}"}}
JSON
fi

exit "${CLAUDE_STUB_EXIT_CODE:-0}"
EOF
chmod +x "$BIN_DIR/claude"

cat > "$LINUX_BIN_DIR/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Linux"
EOF
chmod +x "$LINUX_BIN_DIR/uname"

make_test_home() {
    local home_dir="$1"
    mkdir -p "$home_dir/.claude-switch-backup"
    cat > "$home_dir/.claude-switch-backup/sequence.json" <<'JSON'
{
  "activeAccountNumber": 1,
  "lastUpdated": "2026-04-08T00:00:00Z",
  "sequence": [1],
  "accounts": {
    "1": {
      "email": "alice@example.com",
      "alias": "work",
      "uuid": "uuid-1",
      "serviceName": "claude-code",
      "added": "2026-04-08T00:00:00Z"
    }
  }
}
JSON
}

expected_profile_dir() {
    local home_dir="$1"
    echo "$home_dir/.claude-switch-backup/profiles/account-1-alice-example.com"
}

# Default isolated launch and passthrough args.
HOME_ONE="$TMP_ROOT/home-one"
LOG_ONE="$TMP_ROOT/log-one"
OUT_ONE="$TMP_ROOT/out-one.txt"
make_test_home "$HOME_ONE"
HOME="$HOME_ONE" PATH="$BIN_DIR:$PATH" CLAUDE_STUB_LOG_DIR="$LOG_ONE" \
    bash "$SCRIPT_PATH" --run work -- --model sonnet --effort high >"$OUT_ONE" 2>&1
mapfile -t ARGS_ONE < "$LOG_ONE/args"
PROFILE_ONE=$(cat "$LOG_ONE/config_dir")
assert_eq "$(expected_profile_dir "$HOME_ONE")" "$PROFILE_ONE" "default run should set isolated config dir"
assert_eq "--setting-sources" "${ARGS_ONE[0]}" "default run should pass setting sources flag"
assert_eq "user,project" "${ARGS_ONE[1]}" "default run should exclude local settings"
assert_eq "--model" "${ARGS_ONE[2]}" "default run should preserve passthrough arg order"
assert_eq "sonnet" "${ARGS_ONE[3]}" "default run should preserve passthrough arg values"
assert_eq "--effort" "${ARGS_ONE[4]}" "default run should keep later passthrough args"
assert_eq "high" "${ARGS_ONE[5]}" "default run should keep later passthrough arg values"

# Include local settings when requested.
HOME_TWO="$TMP_ROOT/home-two"
LOG_TWO="$TMP_ROOT/log-two"
OUT_TWO="$TMP_ROOT/out-two.txt"
make_test_home "$HOME_TWO"
HOME="$HOME_TWO" PATH="$BIN_DIR:$PATH" CLAUDE_STUB_LOG_DIR="$LOG_TWO" \
    bash "$SCRIPT_PATH" --run work --include-local-settings -- --resume >"$OUT_TWO" 2>&1
mapfile -t ARGS_TWO < "$LOG_TWO/args"
assert_eq "--setting-sources" "${ARGS_TWO[0]}" "include-local run should pass setting sources flag"
assert_eq "user,project,local" "${ARGS_TWO[1]}" "include-local run should include local settings"
assert_eq "--resume" "${ARGS_TWO[2]}" "include-local run should preserve passthrough args"

# Reject unknown accounts.
HOME_THREE="$TMP_ROOT/home-three"
OUT_THREE="$TMP_ROOT/out-three.txt"
make_test_home "$HOME_THREE"
set +e
HOME="$HOME_THREE" PATH="$BIN_DIR:$PATH" CLAUDE_STUB_LOG_DIR="$TMP_ROOT/log-three" \
    bash "$SCRIPT_PATH" --run missing >"$OUT_THREE" 2>&1
STATUS_THREE=$?
set -e
if [[ "$STATUS_THREE" -eq 0 ]]; then
    fail "unknown account should fail"
fi
assert_contains "$(cat "$OUT_THREE")" "No account found matching: missing" "unknown account error should be clear"

# Pre-launch mismatch should fail before invoking Claude.
HOME_FOUR="$TMP_ROOT/home-four"
OUT_FOUR="$TMP_ROOT/out-four.txt"
LOG_FOUR="$TMP_ROOT/log-four"
make_test_home "$HOME_FOUR"
PROFILE_FOUR="$(expected_profile_dir "$HOME_FOUR")"
mkdir -p "$PROFILE_FOUR"
cat > "$PROFILE_FOUR/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"bob@example.com"}}
JSON
set +e
HOME="$HOME_FOUR" PATH="$BIN_DIR:$PATH" CLAUDE_STUB_LOG_DIR="$LOG_FOUR" \
    bash "$SCRIPT_PATH" --run work >"$OUT_FOUR" 2>&1
STATUS_FOUR=$?
set -e
if [[ "$STATUS_FOUR" -eq 0 ]]; then
    fail "pre-launch mismatch should fail"
fi
assert_contains "$(cat "$OUT_FOUR")" "bob@example.com" "pre-launch mismatch should report current profile email"
assert_contains "$(cat "$OUT_FOUR")" "alice@example.com" "pre-launch mismatch should report expected managed email"
if [[ -f "$LOG_FOUR/args" ]]; then
    fail "pre-launch mismatch should not invoke claude"
fi

# Post-run mismatch should return exit code 2.
HOME_FIVE="$TMP_ROOT/home-five"
OUT_FIVE="$TMP_ROOT/out-five.txt"
make_test_home "$HOME_FIVE"
set +e
HOME="$HOME_FIVE" PATH="$BIN_DIR:$PATH" CLAUDE_STUB_LOG_DIR="$TMP_ROOT/log-five" CLAUDE_STUB_WRITE_EMAIL="bob@example.com" \
    bash "$SCRIPT_PATH" --run work >"$OUT_FIVE" 2>&1
STATUS_FIVE=$?
set -e
assert_eq "2" "$STATUS_FIVE" "post-run mismatch should return exit code 2"
assert_contains "$(cat "$OUT_FIVE")" "bob@example.com" "post-run mismatch should report actual authenticated email"
assert_contains "$(cat "$OUT_FIVE")" "alice@example.com" "post-run mismatch should report expected managed email"

# --run should not require platform credential helpers.
HOME_SIX="$TMP_ROOT/home-six"
LOG_SIX="$TMP_ROOT/log-six"
OUT_SIX="$TMP_ROOT/out-six.txt"
make_test_home "$HOME_SIX"
HOME="$HOME_SIX" PATH="$LINUX_BIN_DIR:$BIN_DIR:$PATH" CLAUDE_STUB_LOG_DIR="$LOG_SIX" \
    bash "$SCRIPT_PATH" --run work >"$OUT_SIX" 2>&1
PROFILE_SIX=$(cat "$LOG_SIX/config_dir")
assert_eq "$(expected_profile_dir "$HOME_SIX")" "$PROFILE_SIX" "--run should work without secret-tool on Linux"

# Credential-writing commands should still fail when the platform helper is missing.
HOME_SEVEN="$TMP_ROOT/home-seven"
OUT_SEVEN="$TMP_ROOT/out-seven.txt"
make_test_home "$HOME_SEVEN"
set +e
HOME="$HOME_SEVEN" PATH="$LINUX_BIN_DIR:$BIN_DIR:$PATH" CLAUDE_STUB_LOG_DIR="$TMP_ROOT/log-seven" \
    bash "$SCRIPT_PATH" --switch work >"$OUT_SEVEN" 2>&1
STATUS_SEVEN=$?
set -e
if [[ "$STATUS_SEVEN" -eq 0 ]]; then
    fail "--switch should fail without secret-tool on Linux"
fi
assert_contains "$(cat "$OUT_SEVEN")" "Required command 'secret-tool' not found" "--switch should still require secret-tool on Linux"

echo "test-run-command.sh: OK"
