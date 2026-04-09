#!/usr/bin/env bash

set -euo pipefail

readonly VERSION="2.1.0" # x-release-please-version
readonly UPDATE_REPO_OWNER="botjaeger"
readonly UPDATE_REPO_NAME="claude-switch"
readonly UPDATE_RELEASE_API_URL="https://api.github.com/repos/${UPDATE_REPO_OWNER}/${UPDATE_REPO_NAME}/releases/latest"
readonly STATE_DIR="$HOME/.claude-switch"
readonly MANIFEST_FILE="$STATE_DIR/manifest.json"
readonly CONFIGS_DIR="$STATE_DIR/configs"
readonly PROFILES_DIR="$STATE_DIR/profiles"
readonly LEGACY_BACKUP_DIR="$HOME/.claude-switch-backup"
readonly LEGACY_SEQUENCE_FILE="$LEGACY_BACKUP_DIR/sequence.json"
readonly LINUX_STORE_SERVICE="claude-switch-v2"
readonly LEGACY_LINUX_SERVICE="claude-code"
readonly WSL_ACTIVE_STORE_BASENAME="active-credentials.enc"
readonly WSL_STORE_DIR_NAME=".claude-switch-v2"
readonly LEGACY_WSL_STORE_DIR_NAME=".claude-switch"

GLOBAL_YES=false
INTERACTIVE_FORCE="${CLAUDE_SWITCH_FORCE_INTERACTIVE:-0}"
PLATFORM_CACHE=""
SPINNER_PID=""
SPINNER_CHARS=( "|" "/" "-" "\\" )

trap 'spinner_stop' EXIT
