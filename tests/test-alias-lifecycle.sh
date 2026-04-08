#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="${1:-./claude-switch.sh}"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-lib.sh"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

HOME_ONE="$TMP_ROOT/home-one"
OUT_ONE="$TMP_ROOT/out-one.txt"
OUT_TWO="$TMP_ROOT/out-two.txt"
OUT_THREE="$TMP_ROOT/out-three.txt"
make_two_account_home "$HOME_ONE"

HOME="$HOME_ONE" bash "$SCRIPT_PATH" alias bob@example.com side >"$OUT_ONE" 2>&1
assert_contains "$(cat "$OUT_ONE")" "Set alias 'side' for bob@example.com" "alias should be assignable"
assert_eq "side" "$(jq -r '.accounts["acct-two"].alias' "$HOME_ONE/.claude-switch/manifest.json")" "alias should persist in the manifest"

set +e
HOME="$HOME_ONE" bash "$SCRIPT_PATH" alias alice@example.com side >"$OUT_TWO" 2>&1
STATUS_TWO=$?
set -e
if [[ "$STATUS_TWO" -eq 0 ]]; then
    fail "duplicate alias should fail"
fi
assert_contains "$(cat "$OUT_TWO")" "Alias 'side' is already used by bob@example.com" "duplicate alias should report the conflicting account"

HOME="$HOME_ONE" bash "$SCRIPT_PATH" unalias side >"$OUT_THREE" 2>&1
assert_contains "$(cat "$OUT_THREE")" "Removed alias from bob@example.com" "unalias should remove the alias"
assert_eq "null" "$(jq -r '.accounts["acct-two"].alias // "null"' "$HOME_ONE/.claude-switch/manifest.json")" "unalias should clear the manifest field"

echo "test-alias-lifecycle.sh: OK"
