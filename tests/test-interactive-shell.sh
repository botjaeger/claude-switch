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
exit 0
EOF
chmod +x "$BIN_DIR/claude"

HOME_ONE="$TMP_ROOT/home-one"
LOG_ONE="$TMP_ROOT/log-one"
OUT_ONE="$TMP_ROOT/out-one.txt"
INPUT_ONE="$TMP_ROOT/input-one.txt"
make_v2_home "$HOME_ONE"

cat > "$INPUT_ONE" <<'EOF'
/help
run work
quit
EOF

HOME="$HOME_ONE" PATH="$BIN_DIR:$PATH" CLAUDE_STUB_LOG_DIR="$LOG_ONE" CLAUDE_SWITCH_FORCE_INTERACTIVE=1 \
    bash "$SCRIPT_PATH" <"$INPUT_ONE" >"$OUT_ONE" 2>&1

PROFILE_ONE=$(cat "$LOG_ONE/config_dir")
OUT_TEXT=$(cat "$OUT_ONE")

assert_eq "$(expected_v2_profile_dir "$HOME_ONE")" "$PROFILE_ONE" "interactive launcher should run the managed profile"
assert_contains "$OUT_TEXT" "claude-switch." "interactive launcher should show the framed brand"
assert_contains "$OUT_TEXT" "launch Claude profiles from one terminal" "interactive launcher should show the new subtitle"
assert_contains "$OUT_TEXT" "session" "interactive launcher should render the session box"
assert_contains "$OUT_TEXT" "managed profiles" "interactive launcher should render the account table"
assert_contains "$OUT_TEXT" "[add] new account" "interactive launcher should render the footer actions"
assert_contains "$OUT_TEXT" "Switch:" "interactive launcher should support /help"
assert_contains "$OUT_TEXT" "claude-switch v" "interactive launcher should show the minimal status line"
assert_contains "$OUT_TEXT" "› " "interactive launcher should show the minimal prompt"

echo "test-interactive-shell.sh: OK"
