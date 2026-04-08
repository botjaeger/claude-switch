check_command_backend_requirements() {
    local command_name="$1"
    case "$command_name" in
        help|version|install|uninstall)
            return 0
            ;;
    esac
    require_command jq || return 1
    backend_requirements_for "$command_name" || return 1
    return 0
}

register_current_global_account() {
    local alias_name="${1:-}"
    local current_email current_creds account_id config_rel profile_rel uuid other_id existing_id existing_alias

    ensure_v2_ready_or_notice || return 1
    check_command_backend_requirements "add" || return 1

    if [[ -n "$alias_name" ]] && ! validate_alias "$alias_name"; then
        error "Invalid alias '$alias_name'. Must be alphanumeric/hyphens/underscores, cannot be purely numeric or an email."
        return 1
    fi

    current_email=$(read_current_global_email)
    if [[ "$current_email" == "none" ]]; then
        error "No active Claude account found. Please finish Claude authentication first."
        return 1
    fi

    existing_id=$(state_find_account_id "$current_email")
    if [[ -n "$existing_id" ]]; then
        if [[ -n "$alias_name" ]]; then
            other_id=$(state_alias_in_use_by_other "$alias_name" "$existing_id")
            if [[ -n "$other_id" ]]; then
                error "Alias '$alias_name' is already used by $(state_account_email "$other_id")"
                return 1
            fi
            existing_alias=$(state_account_alias "$existing_id")
            if [[ "$existing_alias" != "$alias_name" ]]; then
                state_set_alias "$existing_id" "$alias_name" || return 1
                echo "Account $current_email is already managed."
                echo "Set alias '$alias_name' for $current_email"
                return 0
            fi
        fi
        echo "Account $current_email is already managed."
        return 0
    fi

    current_creds=$(global_credentials_read)
    if [[ -z "$current_creds" ]]; then
        error "No credentials found for the active Claude account."
        return 1
    fi

    if [[ -n "$alias_name" ]]; then
        other_id=$(state_alias_in_use_by_other "$alias_name" "")
        if [[ -n "$other_id" ]]; then
            error "Alias '$alias_name' is already used by $(state_account_email "$other_id")"
            return 1
        fi
    fi

    account_id=$(generate_account_id "$current_email")
    config_rel="configs/${account_id}.json"
    profile_rel="profiles/${account_id}-$(sanitize_slug "$current_email")"
    uuid=$(current_oauth_uuid)

    save_account_config_snapshot "$(get_claude_config_path)" "$STATE_DIR/$config_rel" || return 1
    stored_account_credentials_write "$account_id" "$current_email" "$current_creds" || return 1
    state_add_account_record "$account_id" "$current_email" "$uuid" "$alias_name" "$config_rel" "$profile_rel" "" || return 1

    echo "Added account: $current_email"
    if [[ -n "$alias_name" ]]; then
        echo "Alias: $alias_name"
    fi
    return 0
}

command_add() {
    local expected_email="${1:-}"
    local alias_name="${2:-}"
    local before_email after_email rerun_hint

    if [[ $# -lt 1 || $# -gt 2 ]]; then
        error "Usage: claude-switch add <email> [alias]"
        return 1
    fi
    if ! validate_email "$expected_email"; then
        error "Invalid email '$expected_email'"
        return 1
    fi
    if [[ -n "$alias_name" ]] && ! validate_alias "$alias_name"; then
        error "Invalid alias '$alias_name'. Must be alphanumeric/hyphens/underscores, cannot be purely numeric or an email."
        return 1
    fi
    rerun_hint="claude-switch add $expected_email"
    if [[ -n "$alias_name" ]]; then
        rerun_hint+=" $alias_name"
    fi

    ensure_v2_ready_or_notice || return 1
    check_command_backend_requirements "add" || return 1
    if ! command -v claude >/dev/null 2>&1; then
        error "'claude' command not found on PATH"
        return 1
    fi
    before_email=$(read_current_global_email)
    refresh_current_managed_snapshot || return 1

    if [[ "$before_email" != "none" ]]; then
        echo "Signing out Claude Code from $before_email to force re-authentication..."
        if ! claude auth logout; then
            error "Claude Code logout failed."
            return 1
        fi
    fi

    echo "Starting Claude Code login..."
    echo "Finish signing in as $expected_email."
    echo "If the browser shows an Authentication Code, copy it and paste it back into this terminal."
    if ! claude auth login --claudeai; then
        error "Claude Code login did not complete successfully."
        return 1
    fi

    after_email=$(read_current_global_email)
    if [[ "$after_email" == "none" ]]; then
        error "No active Claude account found after authentication."
        echo "Complete sign-in as $expected_email, then run '$rerun_hint' again." >&2
        return 1
    fi
    if [[ "$after_email" != "$expected_email" ]]; then
        error "Authenticated as $after_email, but expected $expected_email."
        if [[ "$before_email" != "none" && "$after_email" == "$before_email" ]]; then
            echo "The browser likely reused your existing Claude session." >&2
        fi
        echo "Sign out or switch accounts in Claude, then run '$rerun_hint' again." >&2
        return 1
    fi
    if state_account_exists_by_email "$after_email"; then
        error "Account $after_email is already managed."
        if [[ -n "$alias_name" ]]; then
            echo "Use 'claude-switch alias $after_email ${alias_name}' to rename it." >&2
        fi
        return 1
    fi

    register_current_global_account "$alias_name"
}

command_list() {
    ensure_v2_ready_or_notice || return 1
    echo "Accounts:"
    if [[ "$(manifest_account_count)" -eq 0 ]]; then
        echo "  (none)"
        return 0
    fi
    state_list_render
}

command_alias() {
    local identifier="$1"
    local alias_name="$2"
    local account_id other_id

    ensure_v2_ready_or_notice || return 1
    if ! validate_alias "$alias_name"; then
        error "Invalid alias '$alias_name'. Must be alphanumeric/hyphens/underscores, cannot be purely numeric or an email."
        return 1
    fi

    account_id=$(state_find_account_id "$identifier")
    if [[ -z "$account_id" ]]; then
        error "No account found matching: $identifier"
        return 1
    fi

    other_id=$(state_alias_in_use_by_other "$alias_name" "$account_id")
    if [[ -n "$other_id" ]]; then
        error "Alias '$alias_name' is already used by $(state_account_email "$other_id")"
        return 1
    fi

    state_set_alias "$account_id" "$alias_name" || return 1
    echo "Set alias '$alias_name' for $(state_account_email "$account_id")"
}

command_unalias() {
    local alias_name="$1"
    local account_id

    ensure_v2_ready_or_notice || return 1
    account_id=$(jq -r --arg alias "$alias_name" '.accounts | to_entries[] | select(.value.alias == $alias) | .key' "$MANIFEST_FILE" 2>/dev/null | head -n1)
    if [[ -z "$account_id" || "$account_id" == "null" ]]; then
        error "No account found with alias: $alias_name"
        return 1
    fi

    state_remove_alias "$account_id" || return 1
    echo "Removed alias from $(state_account_email "$account_id")"
}

command_remove_account() {
    local identifier="$1"
    local account_id email config_path profile_path

    ensure_v2_ready_or_notice || return 1
    check_command_backend_requirements "remove" || return 1

    account_id=$(state_find_account_id "$identifier")
    if [[ -z "$account_id" ]]; then
        error "No account found matching: $identifier"
        return 1
    fi

    email=$(state_account_email "$account_id")
    if [[ "$GLOBAL_YES" != true ]]; then
        if ! prompt_yes_no "Permanently remove $email?"; then
            echo "Cancelled"
            return 0
        fi
    fi

    stored_account_credentials_delete "$account_id" "$email"
    config_path=$(state_account_config_path "$account_id")
    profile_path=$(state_account_profile_path "$account_id")
    rm -f "$config_path"
    rm -rf "$profile_path"
    state_remove_account_record "$account_id" || return 1
    echo "$email has been removed"
}

refresh_current_managed_snapshot() {
    local current_email current_id current_creds current_config

    current_email=$(read_current_global_email)
    if [[ "$current_email" == "none" ]]; then
        return 0
    fi
    current_id=$(state_find_account_id "$current_email")
    if [[ -z "$current_id" ]]; then
        return 0
    fi

    current_creds=$(global_credentials_read)
    if [[ -n "$current_creds" ]]; then
        stored_account_credentials_write "$current_id" "$current_email" "$current_creds" || return 1
    fi
    current_config=$(get_claude_config_path)
    if [[ -f "$current_config" ]]; then
        save_account_config_snapshot "$current_config" "$(state_account_config_path "$current_id")" || return 1
    fi
    return 0
}

command_switch() {
    local identifier="$1"
    local account_id email creds target_config oauth_section merged_config

    ensure_v2_ready_or_notice || return 1
    check_command_backend_requirements "switch" || return 1

    account_id=$(state_find_account_id "$identifier")
    if [[ -z "$account_id" ]]; then
        error "No account found matching: $identifier"
        return 1
    fi

    refresh_current_managed_snapshot || return 1

    email=$(state_account_email "$account_id")
    creds=$(stored_account_credentials_read "$account_id" "$email")
    if [[ -z "$creds" ]]; then
        error "No stored credentials found for $email"
        return 1
    fi
    target_config=$(state_account_config_path "$account_id")
    if [[ ! -f "$target_config" ]]; then
        error "Missing config snapshot for $email"
        return 1
    fi

    global_credentials_write "$creds" || return 1
    oauth_section=$(jq '.oauthAccount' "$target_config" 2>/dev/null)
    if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
        error "Invalid oauthAccount in $target_config"
        return 1
    fi
    if [[ -f "$(get_claude_config_path)" ]] && validate_json_file "$(get_claude_config_path)"; then
        merged_config=$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$(get_claude_config_path)" 2>/dev/null) || {
            error "Failed to merge target auth into current config"
            return 1
        }
    else
        merged_config=$(<"$target_config")
    fi
    write_json "$(get_claude_config_path)" "$merged_config" || return 1
    state_set_active_account "$account_id" || return 1

    echo "Updated global Claude auth to $email"
    echo "Please restart Claude Desktop or Claude Code to use the new authentication."
}

profile_email_for_dir() {
    local profile_dir="$1"
    local config_file="$profile_dir/.claude.json"
    if [[ ! -f "$config_file" ]]; then
        echo ""
        return 0
    fi
    if ! validate_json_file "$config_file"; then
        error "Invalid JSON in $config_file"
        return 1
    fi
    jq -r '.oauthAccount.emailAddress // empty' "$config_file"
}

command_run() {
    local identifier="$1"
    shift
    local include_local=true
    local claude_args=()
    local account_id email profile_dir before_email after_email setting_sources claude_status=0

    ensure_v2_ready_or_notice || return 1

    if ! command -v claude >/dev/null 2>&1; then
        error "'claude' command not found on PATH"
        return 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --include-local-settings)
                include_local=true
                shift
                ;;
            --exclude-local-settings)
                include_local=false
                shift
                ;;
            --)
                shift
                claude_args=("$@")
                break
                ;;
            *)
                error "Unknown option for run: $1"
                return 1
                ;;
        esac
    done

    account_id=$(state_find_account_id "$identifier")
    if [[ -z "$account_id" ]]; then
        error "No account found matching: $identifier"
        return 1
    fi

    email=$(state_account_email "$account_id")
    profile_dir=$(state_account_profile_path "$account_id")
    ensure_dir_secure "$profile_dir"
    link_shared_user_scope_into_profile "$profile_dir"
    link_current_project_memory_into_profile "$profile_dir"

    before_email=$(profile_email_for_dir "$profile_dir") || return 1
    if [[ -n "$before_email" && "$before_email" != "$email" ]]; then
        error "Profile at $profile_dir is authenticated as $before_email, expected $email."
        echo "Remediation: remove that profile directory or run:" >&2
        echo "  CLAUDE_CONFIG_DIR=\"$profile_dir\" claude auth logout" >&2
        return 1
    fi
    if [[ -z "$before_email" ]]; then
        echo "First run for $email."
        echo "The claude CLI will use an isolated profile at $profile_dir."
        echo "This does not change the global Claude config used by Claude Desktop."
        echo "When prompted, sign in as $email."
    fi

    setting_sources="user,project"
    if [[ "$include_local" == true ]]; then
        setting_sources="user,project,local"
    fi

    if CLAUDE_CONFIG_DIR="$profile_dir" command claude --setting-sources "$setting_sources" "${claude_args[@]}"; then
        claude_status=0
    else
        claude_status=$?
    fi

    after_email=$(profile_email_for_dir "$profile_dir") || return 1
    if [[ -n "$after_email" && "$after_email" != "$email" ]]; then
        warn "Profile at $profile_dir is now authenticated as $after_email, expected $email."
        echo "Remediation: remove that profile directory or run:" >&2
        echo "  CLAUDE_CONFIG_DIR=\"$profile_dir\" claude auth logout" >&2
        return 2
    fi

    return "$claude_status"
}

progress_bar() {
    local pct="${1%.*}"
    local width=20
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar+="#"; done
    for ((i=0; i<empty; i++)); do bar+="."; done
    printf '%s %3d%%' "$bar" "$pct"
}

show_usage_metrics() {
    local creds token response now five_util five_reset seven_util seven_reset five_bar seven_bar five_epoch seven_epoch five_msg="" seven_msg=""

    if ! command -v curl >/dev/null 2>&1; then
        return 0
    fi
    creds=$(global_credentials_read)
    if [[ -z "$creds" ]]; then
        return 0
    fi
    token=$(jq -r '.claudeAiOauth.accessToken // empty' <<< "$creds" 2>/dev/null)
    if [[ -z "$token" ]]; then
        return 0
    fi

    spinner_start "Fetching usage..."
    response=$(curl -s --max-time 5 \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
    spinner_stop

    if [[ -z "$response" ]] || ! jq -e '.five_hour' <<< "$response" >/dev/null 2>&1; then
        return 0
    fi

    now=$(date +%s)
    five_util=$(jq -r '.five_hour.utilization // 0' <<< "$response")
    five_reset=$(jq -r '.five_hour.resets_at // empty' <<< "$response")
    seven_util=$(jq -r '.seven_day.utilization // 0' <<< "$response")
    seven_reset=$(jq -r '.seven_day.resets_at // empty' <<< "$response")

    if [[ -n "$five_reset" ]]; then
        five_epoch=$(parse_reset_time_epoch "$five_reset")
        if [[ -n "$five_epoch" ]]; then
            five_msg="  resets in $(format_duration $((five_epoch - now)))"
        fi
    fi
    if [[ -n "$seven_reset" ]]; then
        seven_epoch=$(parse_reset_time_epoch "$seven_reset")
        if [[ -n "$seven_epoch" ]]; then
            seven_msg="  resets in $(format_duration $((seven_epoch - now)))"
        fi
    fi

    five_bar=$(progress_bar "$five_util")
    seven_bar=$(progress_bar "$seven_util")

    echo "Usage:"
    echo "  5-hour: $five_bar$five_msg"
    echo "  7-day:  $seven_bar$seven_msg"
}

command_status() {
    local current_email account_id alias_name

    ensure_v2_ready_or_notice || return 1
    check_command_backend_requirements "status" || return 1

    current_email=$(read_current_global_email)
    if [[ "$current_email" == "none" ]]; then
        echo "No active Claude account found."
        return 0
    fi

    echo "Account: $current_email"
    account_id=$(state_find_account_id "$current_email")
    if [[ -n "$account_id" ]]; then
        alias_name=$(state_account_alias "$account_id")
        if [[ -n "$alias_name" ]]; then
            echo "Alias:   $alias_name"
        fi
    else
        echo "(not managed)"
    fi

    show_usage_metrics
}

command_install() {
    local install_dir="/usr/local/bin"
    local binary_name="claude-switch"
    local source_file="${BASH_SOURCE[0]}"
    local platform

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix)
                if [[ $# -lt 2 ]]; then
                    error "--prefix requires a path argument"
                    return 1
                fi
                install_dir="$2"
                shift 2
                ;;
            *)
                error "Unknown option '$1'"
                return 1
                ;;
        esac
    done

    source_file="$(cd "$(dirname "$source_file")" && pwd)/$(basename "$source_file")"
    platform=$(detect_platform)
    echo "Platform: $platform"

    if ! command -v jq >/dev/null 2>&1; then
        warn "jq is not installed. claude-switch requires jq to run."
    fi
    if [[ "$platform" == "linux" ]] && ! command -v secret-tool >/dev/null 2>&1; then
        warn "secret-tool is not installed. Required for secure credential storage."
    fi
    if [[ "$platform" == "wsl" ]] && ! command -v powershell.exe >/dev/null 2>&1; then
        warn "powershell.exe is not accessible. Required for secure credential storage."
    fi

    if [[ ! -d "$install_dir" ]]; then
        run_maybe_sudo "$(dirname "$install_dir")" mkdir -p "$install_dir"
    fi

    local dest="$install_dir/$binary_name"
    echo "Installing $binary_name to $dest"
    run_maybe_sudo "$install_dir" cp "$source_file" "$dest"
    run_maybe_sudo "$install_dir" chmod +x "$dest"

    case ":$PATH:" in
        *":$install_dir:"*) ;;
        *) warn "$install_dir is not on your PATH." ;;
    esac

    echo "Successfully installed $binary_name to $dest"
}

command_uninstall() {
    local install_dir="/usr/local/bin"
    local binary_name="claude-switch"
    local dest

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix)
                if [[ $# -lt 2 ]]; then
                    error "--prefix requires a path argument"
                    return 1
                fi
                install_dir="$2"
                shift 2
                ;;
            *)
                error "Unknown option '$1'"
                return 1
                ;;
        esac
    done

    dest="$install_dir/$binary_name"
    if [[ ! -f "$dest" ]]; then
        error "$binary_name not found at $dest"
        return 1
    fi

    echo "Removing $dest"
    run_maybe_sudo "$install_dir" rm "$dest"
    echo "Removed $dest"

    if [[ -d "$STATE_DIR" ]]; then
        local confirm="n"
        if [[ "$GLOBAL_YES" == true ]]; then
            confirm="y"
        else
            echo -n "Also remove v2 state ($STATE_DIR)? [y/N] "
            read -r confirm
        fi
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            rm -rf "$STATE_DIR"
            echo "Removed $STATE_DIR"
        fi
    fi

    echo "Successfully uninstalled $binary_name"
}
