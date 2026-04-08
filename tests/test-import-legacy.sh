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
OUT_NOTICE="$TMP_ROOT/out-notice.txt"
OUT_IMPORT="$TMP_ROOT/out-import.txt"
LOG_ONE="$TMP_ROOT/log-one"
SECRET_DIR="$TMP_ROOT/secret-store"
mkdir -p "$HOME_ONE/.claude-switch-backup/configs"
mkdir -p "$HOME_ONE/.claude-switch-backup/profiles/account-1-alice-example.com"
cat > "$HOME_ONE/.claude-switch-backup/sequence.json" <<'JSON'
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
cat > "$HOME_ONE/.claude-switch-backup/configs/.claude-config-1-alice@example.com.json" <<'JSON'
{"oauthAccount":{"emailAddress":"alice@example.com","accountUuid":"uuid-1"}}
JSON
cat > "$HOME_ONE/.claude-switch-backup/profiles/account-1-alice-example.com/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"alice@example.com"}}
JSON

printf '%s' '{"legacy":"credential"}' | HOME="$HOME_ONE" PATH="$BIN_DIR:$PATH" SECRET_TOOL_STUB_DIR="$SECRET_DIR" \
    "$BIN_DIR/secret-tool" store service claude-code account 1 email alice@example.com

set +e
HOME="$HOME_ONE" PATH="$BIN_DIR:$PATH" SECRET_TOOL_STUB_DIR="$SECRET_DIR" CLAUDE_STUB_LOG_DIR="$LOG_ONE" \
    bash "$SCRIPT_PATH" list >"$OUT_NOTICE" 2>&1
STATUS_NOTICE=$?
set -e
if [[ "$STATUS_NOTICE" -eq 0 ]]; then
    fail "list should instruct migration before import"
fi
assert_contains "$(cat "$OUT_NOTICE")" "Run 'claude-switch import-legacy' to migrate it into v2." "legacy notice should explain the import command"

HOME="$HOME_ONE" PATH="$BIN_DIR:$PATH" SECRET_TOOL_STUB_DIR="$SECRET_DIR" CLAUDE_STUB_LOG_DIR="$LOG_ONE" \
    bash "$SCRIPT_PATH" import-legacy >"$OUT_IMPORT" 2>&1
assert_contains "$(cat "$OUT_IMPORT")" "Imported 1 account(s) from legacy state." "import should report success"
assert_contains "$(jq -r '.accounts["legacy-1-alice-example.com"].alias' "$HOME_ONE/.claude-switch/manifest.json")" "work" "import should preserve aliases"
assert_eq '{"legacy":"credential"}' "$(HOME="$HOME_ONE" PATH="$BIN_DIR:$PATH" SECRET_TOOL_STUB_DIR="$SECRET_DIR" "$BIN_DIR/secret-tool" lookup service claude-switch-v2 type account-credentials account_id legacy-1-alice-example.com email alice@example.com)" "import should move credentials into the v2 backend"

HOME="$HOME_ONE" PATH="$BIN_DIR:$PATH" SECRET_TOOL_STUB_DIR="$SECRET_DIR" CLAUDE_STUB_LOG_DIR="$LOG_ONE" \
    bash "$SCRIPT_PATH" run work > /dev/null 2>&1
assert_eq "$HOME_ONE/.claude-switch/profiles/legacy-1-alice-example.com-alice-example.com" "$(cat "$LOG_ONE/config_dir")" "run should use the imported v2 profile path"

echo "test-import-legacy.sh: OK"
