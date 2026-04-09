#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="${1:-./claude-switch.sh}"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-lib.sh"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"

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

# Default isolated launch and passthrough args.
HOME_ONE="$TMP_ROOT/home-one"
LOG_ONE="$TMP_ROOT/log-one"
OUT_ONE="$TMP_ROOT/out-one.txt"
make_v2_home "$HOME_ONE"
mkdir -p "$HOME_ONE/.claude/agents"
PROJECT_KEY="$(pwd | sed 's|/|-|g')"
mkdir -p "$HOME_ONE/.claude/projects/$PROJECT_KEY/memory"
cat > "$HOME_ONE/.claude/settings.json" <<'JSON'
{"theme":"shared"}
JSON
cat > "$HOME_ONE/.claude/agents/reviewer.md" <<'EOF'
# reviewer
EOF
cat > "$HOME_ONE/.claude/projects/$PROJECT_KEY/memory/MEMORY.md" <<'EOF'
# project memory
EOF
PROFILE_ONE_PREEXISTING="$(expected_v2_profile_dir "$HOME_ONE")"
mkdir -p "$PROFILE_ONE_PREEXISTING/agents"
mkdir -p "$PROFILE_ONE_PREEXISTING/projects/$PROJECT_KEY/memory"
cat > "$PROFILE_ONE_PREEXISTING/settings.json" <<'JSON'
{"theme":"stale"}
JSON
cat > "$PROFILE_ONE_PREEXISTING/agents/reviewer.md" <<'EOF'
# stale reviewer
EOF
cat > "$PROFILE_ONE_PREEXISTING/projects/$PROJECT_KEY/memory/MEMORY.md" <<'EOF'
# stale project memory
EOF
HOME="$HOME_ONE" PATH="$BIN_DIR:$PATH" CLAUDE_STUB_LOG_DIR="$LOG_ONE" \
    bash "$SCRIPT_PATH" run work -- --model sonnet --effort high >"$OUT_ONE" 2>&1
mapfile -t ARGS_ONE < "$LOG_ONE/args"
PROFILE_ONE=$(cat "$LOG_ONE/config_dir")
assert_eq "$(expected_v2_profile_dir "$HOME_ONE")" "$PROFILE_ONE" "run should set isolated profile dir"
assert_eq "$HOME_ONE/.claude/settings.json" "$(readlink "$PROFILE_ONE/settings.json")" "run should replace stale profile settings with shared user settings"
assert_eq "$HOME_ONE/.claude/agents/reviewer.md" "$(readlink "$PROFILE_ONE/agents/reviewer.md")" "run should replace stale shared user agents in an existing isolated profile dir"
assert_eq "$HOME_ONE/.claude/projects/$PROJECT_KEY/memory/MEMORY.md" "$(readlink "$PROFILE_ONE/projects/$PROJECT_KEY/memory/MEMORY.md")" "run should replace stale project memory in an existing isolated profile dir"
assert_eq "--setting-sources" "${ARGS_ONE[0]}" "run should pass setting sources flag"
assert_eq "user,project,local" "${ARGS_ONE[1]}" "run should default to user,project,local"
assert_eq "--model" "${ARGS_ONE[2]}" "run should preserve passthrough arg order"
assert_eq "sonnet" "${ARGS_ONE[3]}" "run should preserve passthrough arg values"
assert_eq "--effort" "${ARGS_ONE[4]}" "run should keep later passthrough args"
assert_eq "high" "${ARGS_ONE[5]}" "run should keep later passthrough arg values"

# Exclude local settings when requested.
HOME_TWO="$TMP_ROOT/home-two"
LOG_TWO="$TMP_ROOT/log-two"
OUT_TWO="$TMP_ROOT/out-two.txt"
make_v2_home "$HOME_TWO"
HOME="$HOME_TWO" PATH="$BIN_DIR:$PATH" CLAUDE_STUB_LOG_DIR="$LOG_TWO" \
    bash "$SCRIPT_PATH" run work --exclude-local-settings -- --resume >"$OUT_TWO" 2>&1
mapfile -t ARGS_TWO < "$LOG_TWO/args"
assert_eq "--setting-sources" "${ARGS_TWO[0]}" "exclude-local run should pass setting sources flag"
assert_eq "user,project" "${ARGS_TWO[1]}" "exclude-local run should omit local settings"
assert_eq "--resume" "${ARGS_TWO[2]}" "exclude-local run should preserve passthrough args"

# Include-local flag remains accepted for compatibility.
HOME_COMPAT="$TMP_ROOT/home-compat"
LOG_COMPAT="$TMP_ROOT/log-compat"
OUT_COMPAT="$TMP_ROOT/out-compat.txt"
make_v2_home "$HOME_COMPAT"
HOME="$HOME_COMPAT" PATH="$BIN_DIR:$PATH" CLAUDE_STUB_LOG_DIR="$LOG_COMPAT" \
    bash "$SCRIPT_PATH" run work --include-local-settings -- --resume >"$OUT_COMPAT" 2>&1
mapfile -t ARGS_COMPAT < "$LOG_COMPAT/args"
assert_eq "--setting-sources" "${ARGS_COMPAT[0]}" "include-local compatibility run should pass setting sources flag"
assert_eq "user,project,local" "${ARGS_COMPAT[1]}" "include-local compatibility run should still include local settings"
assert_eq "--resume" "${ARGS_COMPAT[2]}" "include-local compatibility run should preserve passthrough args"

# Reject unknown accounts.
HOME_THREE="$TMP_ROOT/home-three"
OUT_THREE="$TMP_ROOT/out-three.txt"
make_v2_home "$HOME_THREE"
set +e
HOME="$HOME_THREE" PATH="$BIN_DIR:$PATH" CLAUDE_STUB_LOG_DIR="$TMP_ROOT/log-three" \
    bash "$SCRIPT_PATH" run missing >"$OUT_THREE" 2>&1
STATUS_THREE=$?
set -e
if [[ "$STATUS_THREE" -eq 0 ]]; then
    fail "unknown account should fail"
fi
assert_contains "$(cat "$OUT_THREE")" "No account found matching: missing" "unknown account error should be clear"

# Pre-launch mismatch should fail before invoking claude.
HOME_FOUR="$TMP_ROOT/home-four"
OUT_FOUR="$TMP_ROOT/out-four.txt"
LOG_FOUR="$TMP_ROOT/log-four"
make_v2_home "$HOME_FOUR"
PROFILE_FOUR="$(expected_v2_profile_dir "$HOME_FOUR")"
mkdir -p "$PROFILE_FOUR"
cat > "$PROFILE_FOUR/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"bob@example.com"}}
JSON
set +e
HOME="$HOME_FOUR" PATH="$BIN_DIR:$PATH" CLAUDE_STUB_LOG_DIR="$LOG_FOUR" \
    bash "$SCRIPT_PATH" run work >"$OUT_FOUR" 2>&1
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
make_v2_home "$HOME_FIVE"
set +e
HOME="$HOME_FIVE" PATH="$BIN_DIR:$PATH" CLAUDE_STUB_LOG_DIR="$TMP_ROOT/log-five" CLAUDE_STUB_WRITE_EMAIL="bob@example.com" \
    bash "$SCRIPT_PATH" run work >"$OUT_FIVE" 2>&1
STATUS_FIVE=$?
set -e
assert_eq "2" "$STATUS_FIVE" "post-run mismatch should return exit code 2"
assert_contains "$(cat "$OUT_FIVE")" "bob@example.com" "post-run mismatch should report actual authenticated email"
assert_contains "$(cat "$OUT_FIVE")" "alice@example.com" "post-run mismatch should report expected managed email"

# Legacy flag syntax should be rejected with a migration hint.
HOME_SIX="$TMP_ROOT/home-six"
OUT_SIX="$TMP_ROOT/out-six.txt"
make_v2_home "$HOME_SIX"
set +e
HOME="$HOME_SIX" PATH="$BIN_DIR:$PATH" CLAUDE_STUB_LOG_DIR="$TMP_ROOT/log-six" \
    bash "$SCRIPT_PATH" --run work >"$OUT_SIX" 2>&1
STATUS_SIX=$?
set -e
if [[ "$STATUS_SIX" -eq 0 ]]; then
    fail "legacy flag syntax should fail"
fi
assert_contains "$(cat "$OUT_SIX")" "Legacy flag-style syntax is no longer supported in v2." "legacy flag rejection should be explicit"
assert_contains "$(cat "$OUT_SIX")" "Use: claude-switch run <email|alias>" "legacy flag rejection should include the new syntax"

echo "test-run-command.sh: OK"
