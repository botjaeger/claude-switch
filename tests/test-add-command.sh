#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="${1:-./claude-switch.sh}"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-lib.sh"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"

cat > "$BIN_DIR/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Linux"
EOF
chmod +x "$BIN_DIR/uname"

cat > "$BIN_DIR/secret-tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${SECRET_TOOL_STUB_DIR:?}"
mkdir -p "$SECRET_TOOL_STUB_DIR"

make_key() {
  printf '%s' "$*" | sed 's/[^A-Za-z0-9._-]/_/g'
}

cmd="$1"
shift

case "$cmd" in
  store)
    if [[ "$1" == --label=* ]]; then
      shift
    fi
    value="$(cat)"
    key=$(make_key "$@")
    printf '%s' "$value" > "$SECRET_TOOL_STUB_DIR/$key"
    ;;
  lookup)
    key=$(make_key "$@")
    if [[ -f "$SECRET_TOOL_STUB_DIR/$key" ]]; then
      cat "$SECRET_TOOL_STUB_DIR/$key"
    fi
    ;;
  clear)
    key=$(make_key "$@")
    rm -f "$SECRET_TOOL_STUB_DIR/$key"
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$BIN_DIR/secret-tool"

cat > "$BIN_DIR/claude-success" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${CLAUDE_AUTH_LOG:?}"
: "${HOME:?}"

printf '%s\n' "$*" >> "$CLAUDE_AUTH_LOG"

if [[ "${1:-}" == "auth" && "${2:-}" == "logout" ]]; then
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/.claude.json" <<'JSON'
{}
JSON
  secret-tool clear service claude-code type active-credentials >/dev/null 2>&1 || true
  exit 0
fi

if [[ "${1:-}" == "auth" && "${2:-}" == "login" ]]; then
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"bob@example.com","accountUuid":"uuid-2"}}
JSON
  printf '%s' '{"claudeAiOauth":{"accessToken":"token-bob"}}' | secret-tool store --label="Claude Code Active Credentials" \
    service claude-code type active-credentials >/dev/null 2>&1
  exit 0
fi

exit 1
EOF
chmod +x "$BIN_DIR/claude-success"
ln -sf "$BIN_DIR/claude-success" "$BIN_DIR/claude"

HOME_ONE="$TMP_ROOT/home-one"
OUT_ONE="$TMP_ROOT/out-one.txt"
AUTH_LOG="$TMP_ROOT/claude-auth.txt"
SECRET_DIR="$TMP_ROOT/secret-store"
make_v2_home "$HOME_ONE"
mkdir -p "$HOME_ONE/.claude"
cat > "$HOME_ONE/.claude/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"alice@example.com","accountUuid":"uuid-1"}}
JSON

printf '%s' '{"claudeAiOauth":{"accessToken":"token-alice"}}' | HOME="$HOME_ONE" PATH="$BIN_DIR:$PATH" SECRET_TOOL_STUB_DIR="$SECRET_DIR" \
  "$BIN_DIR/secret-tool" store service claude-code type active-credentials

HOME="$HOME_ONE" PATH="$BIN_DIR:$PATH" SECRET_TOOL_STUB_DIR="$SECRET_DIR" CLAUDE_AUTH_LOG="$AUTH_LOG" \
  bash "$SCRIPT_PATH" add bob@example.com side >"$OUT_ONE" 2>&1

OUT_TEXT=$(cat "$OUT_ONE")
assert_contains "$OUT_TEXT" "Signing out Claude Code from alice@example.com to force re-authentication..." "add should force logout before login"
assert_contains "$OUT_TEXT" "Starting Claude Code login..." "add should start the auth flow"
assert_contains "$OUT_TEXT" "copy it and paste it back into this terminal" "add should explain the authentication code handoff"
assert_contains "$OUT_TEXT" "Added account: bob@example.com" "add should register the authenticated account"
assert_contains "$OUT_TEXT" "Alias: side" "add should assign the requested alias"
assert_eq $'auth logout\nauth login --claudeai' "$(cat "$AUTH_LOG")" "add should force logout then invoke Claude Code login"
assert_eq "2" "$(jq -r '.order | length' "$HOME_ONE/.claude-switch/manifest.json")" "add should append a new managed account"

NEW_ID=$(jq -r '.accounts | to_entries[] | select(.value.email=="bob@example.com") | .key' "$HOME_ONE/.claude-switch/manifest.json")
assert_eq "side" "$(jq -r --arg id "$NEW_ID" '.accounts[$id].alias' "$HOME_ONE/.claude-switch/manifest.json")" "add should persist the alias on the new account"
assert_eq '{"claudeAiOauth":{"accessToken":"token-bob"}}' \
  "$(HOME="$HOME_ONE" PATH="$BIN_DIR:$PATH" SECRET_TOOL_STUB_DIR="$SECRET_DIR" "$BIN_DIR/secret-tool" lookup service claude-switch-v2 type account-credentials account_id "$NEW_ID" email bob@example.com)" \
  "add should store credentials for the new managed account"

# If authentication does not switch accounts, add should fail instead of relabeling the current one.
HOME_TWO="$TMP_ROOT/home-two"
OUT_TWO="$TMP_ROOT/out-two.txt"
AUTH_LOG_TWO="$TMP_ROOT/claude-auth-two.txt"
SECRET_DIR_TWO="$TMP_ROOT/secret-store-two"
make_v2_home "$HOME_TWO"
mkdir -p "$HOME_TWO/.claude"
cat > "$HOME_TWO/.claude/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"alice@example.com","accountUuid":"uuid-1"}}
JSON

cat > "$BIN_DIR/claude-nochange" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${CLAUDE_AUTH_LOG:?}"
printf '%s\n' "$*" >> "$CLAUDE_AUTH_LOG"

if [[ "${1:-}" == "auth" && "${2:-}" == "logout" ]]; then
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/.claude.json" <<'JSON'
{}
JSON
  secret-tool clear service claude-code type active-credentials >/dev/null 2>&1 || true
  exit 0
fi

if [[ "${1:-}" == "auth" && "${2:-}" == "login" ]]; then
  exit 0
fi
EOF
chmod +x "$BIN_DIR/claude-nochange"
ln -sf "$BIN_DIR/claude-nochange" "$BIN_DIR/claude"

printf '%s' '{"claudeAiOauth":{"accessToken":"token-alice"}}' | HOME="$HOME_TWO" PATH="$BIN_DIR:$PATH" SECRET_TOOL_STUB_DIR="$SECRET_DIR_TWO" \
  "$BIN_DIR/secret-tool" store service claude-code type active-credentials

set +e
HOME="$HOME_TWO" PATH="$BIN_DIR:$PATH" SECRET_TOOL_STUB_DIR="$SECRET_DIR_TWO" CLAUDE_AUTH_LOG="$AUTH_LOG_TWO" \
  bash "$SCRIPT_PATH" add bob@example.com again >"$OUT_TWO" 2>&1
STATUS_TWO=$?
set -e
if [[ "$STATUS_TWO" -eq 0 ]]; then
    fail "add should fail when the active account did not change"
fi
assert_contains "$(cat "$OUT_TWO")" "No active Claude account found after authentication." "add should explain that login did not establish a new account"
assert_eq "1" "$(jq -r '.order | length' "$HOME_TWO/.claude-switch/manifest.json")" "add should leave the manifest unchanged when auth does not switch accounts"
assert_eq "work" "$(jq -r '.accounts["acct-work"].alias' "$HOME_TWO/.claude-switch/manifest.json")" "add should not relabel the existing managed account"

# If authentication lands on a different email than requested, add should fail clearly.
HOME_THREE="$TMP_ROOT/home-three"
OUT_THREE="$TMP_ROOT/out-three.txt"
AUTH_LOG_THREE="$TMP_ROOT/claude-auth-three.txt"
SECRET_DIR_THREE="$TMP_ROOT/secret-store-three"
make_v2_home "$HOME_THREE"
mkdir -p "$HOME_THREE/.claude"
cat > "$HOME_THREE/.claude/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"alice@example.com","accountUuid":"uuid-1"}}
JSON

ln -sf "$BIN_DIR/claude-success" "$BIN_DIR/claude"
printf '%s' '{"claudeAiOauth":{"accessToken":"token-alice"}}' | HOME="$HOME_THREE" PATH="$BIN_DIR:$PATH" SECRET_TOOL_STUB_DIR="$SECRET_DIR_THREE" \
  "$BIN_DIR/secret-tool" store service claude-code type active-credentials

set +e
HOME="$HOME_THREE" PATH="$BIN_DIR:$PATH" SECRET_TOOL_STUB_DIR="$SECRET_DIR_THREE" CLAUDE_AUTH_LOG="$AUTH_LOG_THREE" \
  bash "$SCRIPT_PATH" add carol@example.com personal >"$OUT_THREE" 2>&1
STATUS_THREE=$?
set -e
if [[ "$STATUS_THREE" -eq 0 ]]; then
    fail "add should fail when Claude authenticates as a different email than requested"
fi
assert_contains "$(cat "$OUT_THREE")" "Authenticated as bob@example.com, but expected carol@example.com." "add should reject mismatched authenticated emails"
assert_eq "1" "$(jq -r '.order | length' "$HOME_THREE/.claude-switch/manifest.json")" "add should leave the manifest unchanged on email mismatch"

echo "test-add-command.sh: OK"
