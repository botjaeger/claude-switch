#!/usr/bin/env bash

# Multi-Account Switcher for Claude Code
# Simple tool to manage and switch between multiple Claude Code accounts

set -euo pipefail

# Configuration
readonly VERSION="1.1.0" # x-release-please-version
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"
YES_FLAG=false

# Container detection
is_running_in_container() {
    if [[ -f /.dockerenv ]]; then
        return 0
    fi
    if [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    if [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null; then
        return 0
    fi
    if [[ -n "${CONTAINER:-}" ]] || [[ -n "${container:-}" ]]; then
        return 0
    fi
    return 1
}

# Platform detection (cached)
_PLATFORM=""
detect_platform() {
    if [[ -n "$_PLATFORM" ]]; then
        echo "$_PLATFORM"
        return
    fi
    case "$(uname -s)" in
        Darwin) _PLATFORM="macos" ;;
        Linux)
            if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
                _PLATFORM="wsl"
            else
                _PLATFORM="linux"
            fi
            ;;
        *) _PLATFORM="unknown" ;;
    esac
    echo "$_PLATFORM"
}

# Get Claude configuration file path with fallback
get_claude_config_path() {
    local primary_config="$HOME/.claude/.claude.json"
    local fallback_config="$HOME/.claude.json"
    if [[ -f "$primary_config" ]]; then
        if jq -e '.oauthAccount' "$primary_config" >/dev/null 2>&1; then
            echo "$primary_config"
            return
        fi
    fi
    echo "$fallback_config"
}

# Basic validation that JSON is valid
validate_json() {
    local file="$1"
    if ! jq . "$file" >/dev/null 2>&1; then
        echo "Error: Invalid JSON in $file"
        return 1
    fi
}

# Email validation function
validate_email() {
    local email="$1"
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Alias validation function
validate_alias() {
    local alias="$1"
    # Must be alphanumeric, hyphens, or underscores
    if [[ ! "$alias" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 1
    fi
    # Must not be purely numeric (those are account numbers)
    if [[ "$alias" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    # Must not look like an email
    if validate_email "$alias"; then
        return 1
    fi
    return 0
}

# Account identifier resolution function
resolve_account_identifier() {
    local identifier="$1"
    local account_num
    # Try email lookup first
    account_num=$(jq -r --arg email "$identifier" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -n "$account_num" && "$account_num" != "null" ]]; then
        echo "$account_num"
        return
    fi
    # Then try alias lookup
    account_num=$(jq -r --arg alias "$identifier" '.accounts | to_entries[] | select(.value.alias == $alias) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -n "$account_num" && "$account_num" != "null" ]]; then
        echo "$account_num"
        return
    fi
    echo ""
}

# Safe JSON write with validation
write_json() {
    local file="$1"
    local content="$2"
    local temp_file
    temp_file=$(mktemp "${file}.XXXXXX")
    echo "$content" > "$temp_file"
    if ! jq . "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        echo "Error: Generated invalid JSON"
        return 1
    fi
    chmod 600 "$temp_file"
    mv "$temp_file" "$file"
}

# Check Bash version (4.4+ required)
check_bash_version() {
    local version
    version=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    if ! awk -v ver="$version" 'BEGIN { exit (ver >= 4.4 ? 0 : 1) }'; then
        echo "Error: Bash 4.4+ required (found $version)"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    for cmd in jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found"
            echo "Install with: apt install $cmd (Linux) or brew install $cmd (macOS)"
            exit 1
        fi
    done
    local platform
    platform=$(detect_platform)
    case "$platform" in
        linux)
            if ! command -v secret-tool >/dev/null 2>&1; then
                echo "Error: Required command 'secret-tool' not found"
                echo "Install with: sudo apt install libsecret-tools"
                exit 1
            fi
            ;;
        wsl)
            if ! command -v powershell.exe >/dev/null 2>&1; then
                echo "Error: powershell.exe not found"
                echo "Ensure Windows interop is enabled and /mnt/c is accessible"
                exit 1
            fi
            ;;
    esac
}

# Installer helpers
needs_sudo() {
    local dir="$1"
    if [[ -w "$dir" ]]; then
        return 1
    fi
    return 0
}

run_cmd() {
    local install_dir="$1"
    shift
    if needs_sudo "$install_dir"; then
        sudo "$@"
    else
        "$@"
    fi
}

# Setup backup directories
setup_directories() {
    mkdir -p "$BACKUP_DIR"/configs
    chmod 700 "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"/configs
    local platform
    platform=$(detect_platform)
    if [[ "$platform" == "macos" ]]; then
        mkdir -p "$BACKUP_DIR"/credentials
        chmod 700 "$BACKUP_DIR"/credentials
    fi
}

# Get current account info from .claude.json
get_current_account() {
    if [[ ! -f "$(get_claude_config_path)" ]]; then
        echo "none"
        return
    fi
    if ! validate_json "$(get_claude_config_path)"; then
        echo "none"
        return
    fi
    local email
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$(get_claude_config_path)" 2>/dev/null)
    echo "${email:-none}"
}

# Detect which Claude Code service name is used in keychain
get_claude_service_name() {
    if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
        echo "Claude Code-credentials"
    elif security find-generic-password -s "Claude Code" >/dev/null 2>&1; then
        echo "Claude Code"
    else
        echo ""
    fi
}

# --- Linux credential functions (libsecret via secret-tool) ---

linux_read_credentials() {
    secret-tool lookup service "claude-code" type "active-credentials" 2>/dev/null || echo ""
}

linux_write_credentials() {
    local credentials="$1"
    printf '%s' "$credentials" | secret-tool store --label="Claude Code Active Credentials" \
        service "claude-code" type "active-credentials" 2>/dev/null
}

linux_read_account_credentials() {
    local account_num="$1"
    local email="$2"
    secret-tool lookup service "claude-code" account "$account_num" email "$email" 2>/dev/null || echo ""
}

linux_write_account_credentials() {
    local account_num="$1"
    local email="$2"
    local credentials="$3"
    printf '%s' "$credentials" | secret-tool store --label="Claude Code Account ${account_num} (${email})" \
        service "claude-code" account "$account_num" email "$email" 2>/dev/null
}

linux_delete_account_credentials() {
    local account_num="$1"
    local email="$2"
    secret-tool clear service "claude-code" account "$account_num" email "$email" 2>/dev/null || true
}

# --- WSL credential functions (Windows DPAPI via powershell.exe) ---

# Get the Windows user profile path accessible from WSL
_wsl_cred_dir() {
    local win_profile
    win_profile=$(powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("UserProfile")' 2>/dev/null | tr -d '\r')
    local wsl_path
    wsl_path=$(wslpath -u "$win_profile" 2>/dev/null)
    echo "${wsl_path}/.claude-switch"
}

wsl_read_credentials() {
    local cred_dir
    cred_dir=$(_wsl_cred_dir)
    local cred_file="${cred_dir}/active-credentials.enc"
    if [[ ! -f "$cred_file" ]]; then
        echo ""
        return
    fi
    local win_path
    win_path=$(wslpath -w "$cred_file" 2>/dev/null)
    if [[ -z "$win_path" ]]; then echo ""; return; fi
    powershell.exe -NoProfile -Command "
        Add-Type -AssemblyName System.Security
        \$bytes = [IO.File]::ReadAllBytes('${win_path}')
        \$plain = [Security.Cryptography.ProtectedData]::Unprotect(\$bytes, \$null, 'CurrentUser')
        [Text.Encoding]::UTF8.GetString(\$plain)
    " 2>/dev/null | tr -d '\r'
}

wsl_write_credentials() {
    local credentials="$1"
    local cred_dir
    cred_dir=$(_wsl_cred_dir)
    mkdir -p "$cred_dir"
    # Write plaintext to temp file to avoid shell injection in PowerShell string
    local tmp_plain
    tmp_plain=$(mktemp "${cred_dir}/.tmp-plain-XXXXXX")
    printf '%s' "$credentials" > "$tmp_plain"
    chmod 600 "$tmp_plain"
    local cred_file="${cred_dir}/active-credentials.enc"
    local win_tmp win_out
    win_tmp=$(wslpath -w "$tmp_plain" 2>/dev/null)
    win_out=$(wslpath -w "$cred_file" 2>/dev/null)
    powershell.exe -NoProfile -Command "
        Add-Type -AssemblyName System.Security
        \$bytes = [IO.File]::ReadAllBytes('${win_tmp}')
        Remove-Item -LiteralPath '${win_tmp}' -Force
        \$enc = [Security.Cryptography.ProtectedData]::Protect(\$bytes, \$null, 'CurrentUser')
        [IO.File]::WriteAllBytes('${win_out}', \$enc)
    " 2>/dev/null
    rm -f "$tmp_plain" 2>/dev/null  # cleanup if PowerShell didn't remove it
}

wsl_read_account_credentials() {
    local account_num="$1"
    local email="$2"
    local cred_dir
    cred_dir=$(_wsl_cred_dir)
    local cred_file="${cred_dir}/account-${account_num}-${email}.enc"
    if [[ ! -f "$cred_file" ]]; then
        echo ""
        return
    fi
    local win_path
    win_path=$(wslpath -w "$cred_file" 2>/dev/null)
    if [[ -z "$win_path" ]]; then echo ""; return; fi
    powershell.exe -NoProfile -Command "
        Add-Type -AssemblyName System.Security
        \$bytes = [IO.File]::ReadAllBytes('${win_path}')
        \$plain = [Security.Cryptography.ProtectedData]::Unprotect(\$bytes, \$null, 'CurrentUser')
        [Text.Encoding]::UTF8.GetString(\$plain)
    " 2>/dev/null | tr -d '\r'
}

wsl_write_account_credentials() {
    local account_num="$1"
    local email="$2"
    local credentials="$3"
    local cred_dir
    cred_dir=$(_wsl_cred_dir)
    mkdir -p "$cred_dir"
    # Write plaintext to temp file to avoid shell injection in PowerShell string
    local tmp_plain
    tmp_plain=$(mktemp "${cred_dir}/.tmp-plain-XXXXXX")
    printf '%s' "$credentials" > "$tmp_plain"
    chmod 600 "$tmp_plain"
    local cred_file="${cred_dir}/account-${account_num}-${email}.enc"
    local win_tmp win_out
    win_tmp=$(wslpath -w "$tmp_plain" 2>/dev/null)
    win_out=$(wslpath -w "$cred_file" 2>/dev/null)
    powershell.exe -NoProfile -Command "
        Add-Type -AssemblyName System.Security
        \$bytes = [IO.File]::ReadAllBytes('${win_tmp}')
        Remove-Item -LiteralPath '${win_tmp}' -Force
        \$enc = [Security.Cryptography.ProtectedData]::Protect(\$bytes, \$null, 'CurrentUser')
        [IO.File]::WriteAllBytes('${win_out}', \$enc)
    " 2>/dev/null
    rm -f "$tmp_plain" 2>/dev/null  # cleanup if PowerShell didn't remove it
}

wsl_delete_account_credentials() {
    local account_num="$1"
    local email="$2"
    local cred_dir
    cred_dir=$(_wsl_cred_dir)
    local cred_file="${cred_dir}/account-${account_num}-${email}.enc"
    if [[ -f "$cred_file" ]]; then
        local win_path
        win_path=$(wslpath -w "$cred_file" 2>/dev/null)
        powershell.exe -NoProfile -Command "Remove-Item -LiteralPath '${win_path}' -Force" 2>/dev/null || true
    fi
}

# Read credentials based on platform
read_credentials() {
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            local service_name
            service_name=$(get_claude_service_name)
            if [[ -n "$service_name" ]]; then
                security find-generic-password -s "$service_name" -w 2>/dev/null || echo ""
            else
                echo ""
            fi
            ;;
        linux)
            linux_read_credentials
            ;;
        wsl)
            wsl_read_credentials
            ;;
    esac
}

# Write credentials based on platform
write_credentials() {
    local credentials="$1"
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            local service_name
            service_name=$(get_claude_service_name)
            if [[ -z "$service_name" ]]; then
                service_name="Claude Code-credentials"
            fi
            security add-generic-password -U -s "$service_name" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux)
            linux_write_credentials "$credentials"
            ;;
        wsl)
            wsl_write_credentials "$credentials"
            ;;
    esac
}

# Read account credentials from backup
read_account_credentials() {
    local account_num="$1"
    local email="$2"
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-Account-${account_num}-${email}" -w 2>/dev/null || echo ""
            ;;
        linux)
            linux_read_account_credentials "$account_num" "$email"
            ;;
        wsl)
            wsl_read_account_credentials "$account_num" "$email"
            ;;
    esac
}

# Write account credentials to backup
write_account_credentials() {
    local account_num="$1"
    local email="$2"
    local credentials="$3"
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux)
            linux_write_account_credentials "$account_num" "$email" "$credentials"
            ;;
        wsl)
            wsl_write_account_credentials "$account_num" "$email" "$credentials"
            ;;
    esac
}

# Read account config from backup
read_account_config() {
    local account_num="$1"
    local email="$2"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    if [[ -f "$config_file" ]]; then
        cat "$config_file"
    else
        echo ""
    fi
}

# Write account config to backup
write_account_config() {
    local account_num="$1"
    local email="$2"
    local config="$3"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    echo "$config" > "$config_file"
    chmod 600 "$config_file"
}

# Initialize sequence.json if it doesn't exist
init_sequence_file() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        local init_content='{
    "activeAccountNumber": null,
    "lastUpdated": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
    "sequence": [],
    "accounts": {}
}'
        write_json "$SEQUENCE_FILE" "$init_content"
    fi
}

# Get next account number
get_next_account_number() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "1"
        return
    fi
    local max_num
    max_num=$(jq -r '.accounts | keys | map(tonumber) | max // 0' "$SEQUENCE_FILE")
    echo $((max_num + 1))
}

# Check if account exists by email
account_exists() {
    local email="$1"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi
    jq -e --arg email "$email" '.accounts[] | select(.email == $email)' "$SEQUENCE_FILE" >/dev/null 2>&1
}

# Add account
cmd_add_account() {
    setup_directories
    init_sequence_file
    local current_email
    current_email=$(get_current_account)
    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found. Please log in first."
        exit 1
    fi
    if account_exists "$current_email"; then
        echo "Account $current_email is already managed."
        exit 0
    fi
    local account_num
    account_num=$(get_next_account_number)
    local platform service_name current_creds current_config config_path
    platform=$(detect_platform)
    if [[ "$platform" == "macos" ]]; then
        service_name=$(get_claude_service_name)
    else
        service_name="claude-code"
    fi
    current_creds=$(read_credentials)
    config_path=$(get_claude_config_path)
    current_config=$(<"$config_path")
    if [[ -z "$current_creds" ]]; then
        echo "Error: No credentials found for current account"
        exit 1
    fi
    if [[ "$platform" == "macos" && -z "$service_name" ]]; then
        echo "Error: Could not determine Claude Code service name"
        exit 1
    fi
    local account_uuid
    account_uuid=$(jq -r '.oauthAccount.accountUuid' "$(get_claude_config_path)")
    write_account_credentials "$account_num" "$current_email" "$current_creds"
    write_account_config "$account_num" "$current_email" "$current_config"
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg email "$current_email" --arg uuid "$account_uuid" --arg service "$service_name" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num] = {
            email: $email,
            uuid: $uuid,
            serviceName: $service,
            added: $now
        } |
        .sequence += [$num | tonumber] |
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    echo "Added account: $current_email (service: $service_name)"
}

# Remove account
cmd_remove_account() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --remove-account <email|alias>"
        exit 1
    fi
    local identifier="$1"
    local account_num
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    account_num=$(resolve_account_identifier "$identifier")
    if [[ -z "$account_num" ]]; then
        echo "Error: No account found matching: $identifier"
        exit 1
    fi
    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    if [[ -z "$account_info" ]]; then
        echo "Error: Account not found: $identifier"
        exit 1
    fi
    local email
    email=$(jq -r '.email' <<< "$account_info")
    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    if [[ "$active_account" == "$account_num" ]]; then
        echo "Warning: $email is currently active"
    fi
    if [[ "$YES_FLAG" != true ]]; then
        echo -n "Are you sure you want to permanently remove $email? [y/N] "
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Cancelled"
            exit 0
        fi
    fi
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security delete-generic-password -s "Claude Code-Account-${account_num}-${email}" 2>/dev/null || true
            ;;
        linux)
            linux_delete_account_credentials "$account_num" "$email"
            ;;
        wsl)
            wsl_delete_account_credentials "$account_num" "$email"
            ;;
    esac
    rm -f "$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.accounts[$num]) |
        .sequence = (.sequence | map(select(. != ($num | tonumber)))) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    echo "$email has been removed"
}

# Set alias for an account
cmd_alias() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 --alias <email|alias> <alias_name>"
        exit 1
    fi
    local identifier="$1"
    local alias_name="$2"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    if ! validate_alias "$alias_name"; then
        echo "Error: Invalid alias '$alias_name'. Must be alphanumeric/hyphens/underscores, cannot be purely numeric or an email."
        exit 1
    fi
    local account_num
    account_num=$(resolve_account_identifier "$identifier")
    if [[ -z "$account_num" ]]; then
        echo "Error: No account found matching: $identifier"
        exit 1
    fi
    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    if [[ -z "$account_info" ]]; then
        echo "Error: Account not found: $identifier"
        exit 1
    fi
    # Check for duplicate alias
    local existing
    existing=$(jq -r --arg alias "$alias_name" '.accounts | to_entries[] | select(.value.alias == $alias) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -n "$existing" && "$existing" != "null" ]]; then
        local existing_email
        existing_email=$(jq -r --arg num "$existing" '.accounts[$num].email' "$SEQUENCE_FILE")
        echo "Error: Alias '$alias_name' is already used by $existing_email"
        exit 1
    fi
    local email
    email=$(jq -r --arg num "$account_num" '.accounts[$num].email' "$SEQUENCE_FILE")
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg alias "$alias_name" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num].alias = $alias |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    echo "Set alias '$alias_name' for $email"
}

# Remove alias from an account
cmd_unalias() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --unalias <alias_name>"
        exit 1
    fi
    local alias_name="$1"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    local account_num
    account_num=$(jq -r --arg alias "$alias_name" '.accounts | to_entries[] | select(.value.alias == $alias) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -z "$account_num" || "$account_num" == "null" ]]; then
        echo "Error: No account found with alias: $alias_name"
        exit 1
    fi
    local email
    email=$(jq -r --arg num "$account_num" '.accounts[$num].email' "$SEQUENCE_FILE")
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num] |= del(.alias) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    echo "Removed alias from $email"
}

# List accounts
cmd_list() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts managed yet. Run '$0 --add-account' to add one."
        exit 0
    fi
    local current_email
    current_email=$(get_current_account)
    local active_account_num=""
    if [[ "$current_email" != "none" ]]; then
        active_account_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    fi
    echo "Accounts:"
    jq -r --arg active "$active_account_num" '
        .sequence[] as $num |
        .accounts["\($num)"] |
        "  \(.email)" +
        (if .alias then " [\(.alias)]" else "" end) +
        (if "\($num)" == $active then " (active)" else "" end)
    ' "$SEQUENCE_FILE"
}

# Switch to specific account
cmd_switch() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --switch <email|alias>"
        exit 1
    fi
    local identifier="$1"
    local target_account
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    target_account=$(resolve_account_identifier "$identifier")
    if [[ -z "$target_account" ]]; then
        echo "Error: No account found matching: $identifier"
        exit 1
    fi
    local account_info
    account_info=$(jq -r --arg num "$target_account" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    if [[ -z "$account_info" ]]; then
        echo "Error: Account not found: $identifier"
        exit 1
    fi
    perform_switch "$target_account"
}

# Perform the actual account switch
perform_switch() {
    local target_account="$1"
    local platform
    platform=$(detect_platform)
    local current_account target_email current_email target_service current_service
    current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    target_email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")
    target_service=$(jq -r --arg num "$target_account" '.accounts[$num].serviceName // empty' "$SEQUENCE_FILE")
    current_email=$(get_current_account)
    if [[ "$platform" == "macos" ]]; then
        current_service=$(get_claude_service_name)
        if [[ -z "$target_service" ]]; then
            echo "Error: No service name stored for $target_email. Re-add this account."
            exit 1
        fi
    fi
    local current_creds current_config config_path
    current_creds=$(read_credentials)
    config_path=$(get_claude_config_path)
    current_config=$(<"$config_path")
    write_account_credentials "$current_account" "$current_email" "$current_creds"
    write_account_config "$current_account" "$current_email" "$current_config"
    local target_creds target_config
    target_creds=$(read_account_credentials "$target_account" "$target_email")
    target_config=$(read_account_config "$target_account" "$target_email")
    if [[ -z "$target_creds" || -z "$target_config" ]]; then
        echo "Error: Missing backup data for $target_email"
        exit 1
    fi
    if [[ "$platform" == "macos" ]]; then
        if [[ -n "$current_service" && "$current_service" != "$target_service" ]]; then
            security delete-generic-password -s "$current_service" 2>/dev/null || true
            echo "Removed old keychain entry: $current_service"
        fi
        security add-generic-password -U -s "$target_service" -a "$USER" -w "$target_creds" 2>/dev/null
        echo "Added keychain entry: $target_service"
    else
        write_credentials "$target_creds"
        echo "Updated credentials store"
    fi
    local oauth_section
    oauth_section=$(jq '.oauthAccount' <<< "$target_config" 2>/dev/null)
    if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
        echo "Error: Invalid oauthAccount in backup"
        exit 1
    fi
    local merged_config
    merged_config=$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$(get_claude_config_path)" 2>/dev/null) || {
        echo "Error: Failed to merge config"
        exit 1
    }
    write_json "$(get_claude_config_path)" "$merged_config"
    local updated_sequence
    updated_sequence=$(jq --arg num "$target_account" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    if [[ "$platform" == "macos" ]]; then
        echo "Switched to $target_email (service: $target_service)"
    else
        echo "Switched to $target_email"
    fi
    cmd_list
    echo ""
    echo "Please restart Claude Code to use the new authentication."
    echo ""
}

# Install claude-switch
cmd_install() {
    local default_prefix="/usr/local/bin"
    local install_dir="$default_prefix"
    local binary_name="claude-switch"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix)
                if [[ $# -lt 2 ]]; then
                    echo "Error: --prefix requires a path argument"
                    exit 1
                fi
                install_dir="$2"
                shift 2
                ;;
            *)
                echo "Error: Unknown option '$1'"
                exit 1
                ;;
        esac
    done

    local source_file="${BASH_SOURCE[0]}"
    if [[ -z "$source_file" ]]; then
        echo "Error: Cannot determine source file path (pipe install is not supported)"
        echo "Download the script first, then run: bash claude-switch.sh --install"
        exit 1
    fi
    source_file="$(cd "$(dirname "$source_file")" && pwd)/$(basename "$source_file")"

    local platform
    platform=$(detect_platform)
    echo "Platform: $platform"

    # Soft warnings (don't block install)
    if ! command -v jq >/dev/null 2>&1; then
        echo "Warning: jq is not installed. claude-switch requires jq to run."
        if [[ "$platform" == "macos" ]]; then
            echo "  Install with: brew install jq"
        else
            echo "  Install with: apt install jq"
        fi
    fi

    if [[ "$platform" == "linux" ]] && ! command -v secret-tool >/dev/null 2>&1; then
        echo "Warning: secret-tool is not installed. Required for secure credential storage."
        echo "  Install with: sudo apt install libsecret-tools"
    fi
    if [[ "$platform" == "wsl" ]] && ! command -v powershell.exe >/dev/null 2>&1; then
        echo "Warning: powershell.exe not accessible. Required for secure credential storage."
        echo "  Ensure Windows interop is enabled and /mnt/c is accessible."
    fi

    local bash_version
    bash_version=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    if ! awk -v ver="$bash_version" 'BEGIN { exit (ver >= 4.4 ? 0 : 1) }'; then
        echo "Warning: Bash 4.4+ is recommended (found $bash_version)."
        if [[ "$platform" == "macos" ]]; then
            echo "  Install with: brew install bash"
        fi
    fi

    if [[ ! -d "$install_dir" ]]; then
        echo "Creating directory: $install_dir"
        # Check parent since target doesn't exist yet
        if needs_sudo "$(dirname "$install_dir")"; then
            sudo mkdir -p "$install_dir"
        else
            mkdir -p "$install_dir"
        fi
    fi

    local dest="$install_dir/$binary_name"
    echo "Installing $binary_name to $dest"
    run_cmd "$install_dir" cp "$source_file" "$dest"
    run_cmd "$install_dir" chmod +x "$dest"

    case ":$PATH:" in
        *":$install_dir:"*) ;;
        *)
            echo "Warning: $install_dir is not on your PATH."
            echo "  Add it with: export PATH=\"$install_dir:\$PATH\""
            ;;
    esac

    echo "Successfully installed $binary_name to $dest"
}

# Uninstall claude-switch
cmd_uninstall() {
    local default_prefix="/usr/local/bin"
    local install_dir="$default_prefix"
    local binary_name="claude-switch"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix)
                if [[ $# -lt 2 ]]; then
                    echo "Error: --prefix requires a path argument"
                    exit 1
                fi
                install_dir="$2"
                shift 2
                ;;
            *)
                echo "Error: Unknown option '$1'"
                exit 1
                ;;
        esac
    done

    local dest="$install_dir/$binary_name"

    if [[ ! -f "$dest" ]]; then
        echo "Error: $binary_name not found at $dest"
        exit 1
    fi

    echo "Removing $dest"
    run_cmd "$install_dir" rm "$dest"
    echo "Removed $dest"

    if [[ -d "$BACKUP_DIR" ]]; then
        local confirm="n"
        if [[ "$YES_FLAG" == true ]]; then
            confirm="y"
        else
            echo -n "Also remove account data ($BACKUP_DIR)? [y/N] "
            read -r confirm
        fi
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            rm -rf "$BACKUP_DIR"
            echo "Removed $BACKUP_DIR"
            local platform
            platform=$(detect_platform)
            case "$platform" in
                macos)
                    echo "Note: Keychain entries for 'Claude Code-Account-*' were NOT removed."
                    echo "  To remove them manually, use: security delete-generic-password -s <service-name>"
                    ;;
                linux)
                    echo "Note: libsecret keyring entries for 'claude-code' were NOT removed."
                    echo "  To remove them manually, use: secret-tool clear service claude-code account <N> email <email>"
                    ;;
                wsl)
                    echo "Note: DPAPI-encrypted files in %USERPROFILE%\\.claude-switch were NOT removed."
                    echo "  To remove them manually, delete the .claude-switch folder in your Windows user profile."
                    ;;
            esac
        fi
    fi

    echo "Successfully uninstalled $binary_name"
}

# Format seconds into human-readable duration
format_duration() {
    local seconds="$1"
    if [[ "$seconds" -le 0 ]]; then
        echo "now"
        return
    fi
    local days=$((seconds / 86400))
    local hours=$(( (seconds % 86400) / 3600 ))
    local minutes=$(( (seconds % 3600) / 60 ))
    local parts=()
    [[ $days -gt 0 ]] && parts+=("${days}d")
    [[ $hours -gt 0 ]] && parts+=("${hours}h")
    [[ $days -eq 0 && $minutes -gt 0 ]] && parts+=("${minutes}m")
    echo "${parts[*]}"
}

# Spinner for async operations
_SPINNER_PID=""
_SPINNER_CHARS=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
trap 'spinner_stop' EXIT

spinner_start() {
    local msg="$1"
    (
        while true; do
            for c in "${_SPINNER_CHARS[@]}"; do
                printf '\r%s %s' "$c" "$msg"
                sleep 0.1
            done
        done
    ) &
    _SPINNER_PID=$!
}

spinner_stop() {
    if [[ -n "$_SPINNER_PID" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null || true
        wait "$_SPINNER_PID" 2>/dev/null || true
        _SPINNER_PID=""
        printf '\r\033[K'
    fi
}

# Fetch and display token usage from Claude API
show_token_usage() {
    if ! command -v curl >/dev/null 2>&1; then
        return
    fi
    local creds
    creds=$(read_credentials)
    if [[ -z "$creds" ]]; then
        return
    fi
    local token
    token=$(jq -r '.claudeAiOauth.accessToken // empty' <<< "$creds" 2>/dev/null)
    if [[ -z "$token" ]]; then
        return
    fi
    spinner_start "Fetching usage..."
    local response
    response=$(curl -s --max-time 5 \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
    spinner_stop
    if [[ -z "$response" ]] || ! jq -e '.five_hour' <<< "$response" >/dev/null 2>&1; then
        return
    fi
    local now
    now=$(date +%s)
    local five_util five_reset seven_util seven_reset
    five_util=$(jq -r '.five_hour.utilization // 0' <<< "$response")
    five_reset=$(jq -r '.five_hour.resets_at // empty' <<< "$response")
    seven_util=$(jq -r '.seven_day.utilization // 0' <<< "$response")
    seven_reset=$(jq -r '.seven_day.resets_at // empty' <<< "$response")
    # Parse ISO 8601 UTC timestamp to epoch seconds
    parse_reset_time() {
        local ts="$1"
        local epoch=""
        # macOS: -u for UTC, strip fractional seconds and timezone
        epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null) || \
        # Linux: date -d handles ISO 8601 natively
        epoch=$(date -d "$ts" +%s 2>/dev/null) || epoch=""
        echo "$epoch"
    }
    local five_dur="" seven_dur=""
    if [[ -n "$five_reset" ]]; then
        local five_epoch
        five_epoch=$(parse_reset_time "$five_reset")
        if [[ -n "$five_epoch" ]]; then
            five_dur=$(format_duration $((five_epoch - now)))
        fi
    fi
    if [[ -n "$seven_reset" ]]; then
        local seven_epoch
        seven_epoch=$(parse_reset_time "$seven_reset")
        if [[ -n "$seven_epoch" ]]; then
            seven_dur=$(format_duration $((seven_epoch - now)))
        fi
    fi
    # Build progress bar: ████████░░░░░░░░░░░░ 15%
    progress_bar() {
        local pct="${1%.*}"
        local width=20
        local filled=$(( pct * width / 100 ))
        local empty=$(( width - filled ))
        local bar=""
        for ((i=0; i<filled; i++)); do bar+="█"; done
        for ((i=0; i<empty; i++)); do bar+="░"; done
        printf '%s %3d%%' "$bar" "$pct"
    }
    local five_bar seven_bar
    five_bar=$(progress_bar "$five_util")
    seven_bar=$(progress_bar "$seven_util")
    local five_reset_str="" seven_reset_str=""
    [[ -n "$five_dur" ]] && five_reset_str="  resets in $five_dur"
    [[ -n "$seven_dur" ]] && seven_reset_str="  resets in $seven_dur"
    echo "Usage:"
    echo "  5-hour: $five_bar$five_reset_str"
    echo "  7-day:  $seven_bar$seven_reset_str"
}

# Show current account status
cmd_status() {
    local current_email
    current_email=$(get_current_account)
    if [[ "$current_email" == "none" ]]; then
        echo "No active Claude account found."
        return
    fi
    echo "Account: $current_email"
    if [[ -f "$SEQUENCE_FILE" ]]; then
        local account_num
        account_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ -n "$account_num" && "$account_num" != "null" ]]; then
            local alias_name
            alias_name=$(jq -r --arg num "$account_num" '.accounts[$num].alias // empty' "$SEQUENCE_FILE")
            if [[ -n "$alias_name" ]]; then
                echo "Alias:   $alias_name"
            fi
        else
            echo "(not managed)"
        fi
    else
        echo "(not managed)"
    fi
    show_token_usage
}

# Show usage
show_usage() {
    echo "Multi-Account Switcher for Claude Code"
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  --add-account                    Add current account to managed accounts"
    echo "  --remove-account <email|alias>   Remove account by email or alias"
    echo "  --list                           List all managed accounts"
    echo "  --switch <email|alias>           Switch to specific account"
    echo "  --status, --whoami               Show current account info"
    echo "  --alias <email|alias> <name>     Set an alias for an account"
    echo "  --unalias <alias_name>           Remove an alias from an account"
    echo "  --install [--prefix /path]       Install to /usr/local/bin (or custom path)"
    echo "  --uninstall [--prefix /path]     Uninstall claude-switch"
    echo "  --version                        Show version number"
    echo "  --help                           Show this help message"
    echo ""
    echo "Options:"
    echo "  -y, --yes                        Skip confirmation prompts"
    echo ""
    echo "Examples:"
    echo "  $0 --add-account"
    echo "  $0 --list"
    echo "  $0 --switch user@example.com"
    echo "  $0 --alias user@example.com work"
    echo "  $0 --switch work"
    echo "  $0 --unalias work"
    echo "  $0 --remove-account work"
}

# Main script logic
main() {
    # Pre-scan for -y/--yes flag
    local args=()
    for arg in "$@"; do
        case "$arg" in
            -y|--yes) YES_FLAG=true ;;
            *) args+=("$arg") ;;
        esac
    done
    set -- "${args[@]+"${args[@]}"}"

    # Handle install/uninstall/help/version before dependency checks
    case "${1:-}" in
        --install)
            shift
            cmd_install "$@"
            return
            ;;
        --uninstall)
            shift
            cmd_uninstall "$@"
            return
            ;;
        --version)
            echo "claude-switch $VERSION"
            return
            ;;
        --help|"")
            show_usage
            return
            ;;
    esac

    if [[ $EUID -eq 0 ]] && ! is_running_in_container; then
        echo "Error: Do not run this script as root (unless running in a container)"
        exit 1
    fi
    check_bash_version
    check_dependencies
    case "${1:-}" in
        --add-account)
            cmd_add_account
            ;;
        --remove-account)
            shift
            cmd_remove_account "$@"
            ;;
        --list)
            cmd_list
            ;;
        --switch)
            shift
            cmd_switch "$@"
            ;;
        --alias)
            shift
            cmd_alias "$@"
            ;;
        --unalias)
            shift
            cmd_unalias "$@"
            ;;
        --status|--whoami)
            cmd_status
            ;;
        *)
            echo "Error: Unknown command '$1'"
            show_usage
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
