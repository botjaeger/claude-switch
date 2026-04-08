#!/usr/bin/env bash

set -euo pipefail

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

make_v2_home() {
    local home_dir="$1"
    mkdir -p "$home_dir/.claude-switch/configs"
    mkdir -p "$home_dir/.claude-switch/profiles"
    cat > "$home_dir/.claude-switch/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "createdAt": "2026-04-08T00:00:00Z",
  "lastUpdated": "2026-04-08T00:00:00Z",
  "importedLegacy": false,
  "activeAccountId": "acct-work",
  "order": ["acct-work"],
  "accounts": {
    "acct-work": {
      "id": "acct-work",
      "email": "alice@example.com",
      "alias": "work",
      "uuid": "uuid-1",
      "configFile": "configs/acct-work.json",
      "profileDir": "profiles/acct-work-alice-example.com",
      "createdAt": "2026-04-08T00:00:00Z",
      "updatedAt": "2026-04-08T00:00:00Z"
    }
  }
}
JSON
    cat > "$home_dir/.claude-switch/configs/acct-work.json" <<'JSON'
{"oauthAccount":{"emailAddress":"alice@example.com","accountUuid":"uuid-1"}}
JSON
}

make_two_account_home() {
    local home_dir="$1"
    mkdir -p "$home_dir/.claude-switch/configs"
    mkdir -p "$home_dir/.claude-switch/profiles"
    cat > "$home_dir/.claude-switch/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "createdAt": "2026-04-08T00:00:00Z",
  "lastUpdated": "2026-04-08T00:00:00Z",
  "importedLegacy": false,
  "activeAccountId": "acct-one",
  "order": ["acct-one", "acct-two"],
  "accounts": {
    "acct-one": {
      "id": "acct-one",
      "email": "alice@example.com",
      "alias": "work",
      "uuid": "uuid-1",
      "configFile": "configs/acct-one.json",
      "profileDir": "profiles/acct-one-alice-example.com",
      "createdAt": "2026-04-08T00:00:00Z",
      "updatedAt": "2026-04-08T00:00:00Z"
    },
    "acct-two": {
      "id": "acct-two",
      "email": "bob@example.com",
      "alias": "personal",
      "uuid": "uuid-2",
      "configFile": "configs/acct-two.json",
      "profileDir": "profiles/acct-two-bob-example.com",
      "createdAt": "2026-04-08T00:00:00Z",
      "updatedAt": "2026-04-08T00:00:00Z"
    }
  }
}
JSON
    cat > "$home_dir/.claude-switch/configs/acct-one.json" <<'JSON'
{"oauthAccount":{"emailAddress":"alice@example.com","accountUuid":"uuid-1"}}
JSON
    cat > "$home_dir/.claude-switch/configs/acct-two.json" <<'JSON'
{"oauthAccount":{"emailAddress":"bob@example.com","accountUuid":"uuid-2"}}
JSON
}

expected_v2_profile_dir() {
    local home_dir="$1"
    echo "$home_dir/.claude-switch/profiles/acct-work-alice-example.com"
}
