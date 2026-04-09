#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="${1:-./claude-switch.sh}"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-lib.sh"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

PREFIX="$TMP_ROOT/bin"
HOME_ONE="$TMP_ROOT/home-one"
STUB_BIN="$TMP_ROOT/stub-bin"
UPDATED_SCRIPT="$TMP_ROOT/updated-claude-switch.sh"
OUT_ONE="$TMP_ROOT/out-one.txt"
OUT_TWO="$TMP_ROOT/out-two.txt"

mkdir -p "$HOME_ONE" "$STUB_BIN"

sed 's/^readonly VERSION="[^"]*"/readonly VERSION="9.9.9"/' "$SCRIPT_PATH" > "$UPDATED_SCRIPT"
chmod +x "$UPDATED_SCRIPT"

cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${CLAUDE_SWITCH_TEST_UPDATE_SOURCE:?}"

output=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)
            output="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [[ -z "$output" ]]; then
    echo "curl stub expected -o <path>" >&2
    exit 1
fi

cp "$CLAUDE_SWITCH_TEST_UPDATE_SOURCE" "$output"
EOF
chmod +x "$STUB_BIN/curl"

HOME="$HOME_ONE" bash "$SCRIPT_PATH" install --prefix "$PREFIX" >/dev/null 2>&1

HOME="$HOME_ONE" PATH="$STUB_BIN:$PATH" CLAUDE_SWITCH_UPDATE_URL="https://example.invalid/claude-switch.sh" \
    CLAUDE_SWITCH_TEST_UPDATE_SOURCE="$UPDATED_SCRIPT" \
    bash "$PREFIX/claude-switch" update --prefix "$PREFIX" >"$OUT_ONE" 2>&1
assert_contains "$(cat "$OUT_ONE")" "Successfully updated claude-switch to 9.9.9" "update should report the installed version it applied"
assert_contains "$(bash "$PREFIX/claude-switch" version)" "claude-switch 9.9.9" "update should replace the installed binary"
if [[ ! -x "$PREFIX/claude-switch" ]]; then
    fail "update should keep the installed binary executable"
fi

HOME="$HOME_ONE" PATH="$STUB_BIN:$PATH" CLAUDE_SWITCH_UPDATE_URL="https://example.invalid/claude-switch.sh" \
    CLAUDE_SWITCH_TEST_UPDATE_SOURCE="$UPDATED_SCRIPT" \
    bash "$PREFIX/claude-switch" update --prefix "$PREFIX" >"$OUT_TWO" 2>&1
assert_contains "$(cat "$OUT_TWO")" "claude-switch is already up to date (9.9.9)" "update should no-op when the installed version already matches the latest release"

echo "test-update-command.sh: OK"
