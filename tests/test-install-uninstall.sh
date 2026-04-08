#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="${1:-./claude-switch.sh}"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-lib.sh"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

PREFIX="$TMP_ROOT/bin"
HOME_ONE="$TMP_ROOT/home-one"
OUT_ONE="$TMP_ROOT/out-one.txt"
OUT_TWO="$TMP_ROOT/out-two.txt"
OUT_THREE="$TMP_ROOT/out-three.txt"

mkdir -p "$HOME_ONE"

HOME="$HOME_ONE" bash "$SCRIPT_PATH" install --prefix "$PREFIX" >"$OUT_ONE" 2>&1
assert_contains "$(cat "$OUT_ONE")" "Successfully installed claude-switch" "install should succeed"
if [[ ! -x "$PREFIX/claude-switch" ]]; then
    fail "install should create an executable binary"
fi

mkdir -p "$HOME_ONE/.claude-switch"
HOME="$HOME_ONE" bash "$PREFIX/claude-switch" uninstall --prefix "$PREFIX" -y >"$OUT_TWO" 2>&1
assert_contains "$(cat "$OUT_TWO")" "Successfully uninstalled claude-switch" "uninstall should succeed"
if [[ -e "$PREFIX/claude-switch" ]]; then
    fail "uninstall should remove the installed binary"
fi
if [[ -d "$HOME_ONE/.claude-switch" ]]; then
    fail "uninstall -y should remove v2 state"
fi

HOME="$HOME_ONE" bash "$SCRIPT_PATH" install --prefix "$PREFIX" > /dev/null 2>&1
mkdir -p "$HOME_ONE/.claude-switch"
printf 'n\n' | HOME="$HOME_ONE" bash "$PREFIX/claude-switch" uninstall --prefix "$PREFIX" >"$OUT_THREE" 2>&1
if [[ ! -d "$HOME_ONE/.claude-switch" ]]; then
    fail "uninstall without confirmation should keep v2 state"
fi

echo "test-install-uninstall.sh: OK"
