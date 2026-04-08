current_macos_global_service() {
    if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
        echo "Claude Code-credentials"
        return 0
    fi
    if security find-generic-password -s "Claude Code" >/dev/null 2>&1; then
        echo "Claude Code"
        return 0
    fi
    echo ""
}

wsl_store_dir() {
    local basename="$1"
    local win_profile
    local wsl_profile

    win_profile=$(powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("UserProfile")' 2>/dev/null | tr -d '\r')
    wsl_profile=$(wslpath -u "$win_profile" 2>/dev/null)
    printf '%s/%s\n' "$wsl_profile" "$basename"
}

wsl_encrypt_to_file() {
    local plaintext="$1"
    local output_file="$2"
    local dir tmp_plain win_tmp win_out

    dir=$(dirname "$output_file")
    mkdir -p "$dir"
    chmod 700 "$dir"
    tmp_plain=$(mktemp "${dir}/.tmp-plain-XXXXXX")
    printf '%s' "$plaintext" > "$tmp_plain"
    chmod 600 "$tmp_plain"
    win_tmp=$(wslpath -w "$tmp_plain" 2>/dev/null)
    win_out=$(wslpath -w "$output_file" 2>/dev/null)
    powershell.exe -NoProfile -Command "
        Add-Type -AssemblyName System.Security
        \$bytes = [IO.File]::ReadAllBytes('${win_tmp}')
        Remove-Item -LiteralPath '${win_tmp}' -Force
        \$enc = [Security.Cryptography.ProtectedData]::Protect(\$bytes, \$null, 'CurrentUser')
        [IO.File]::WriteAllBytes('${win_out}', \$enc)
    " >/dev/null 2>&1
    rm -f "$tmp_plain" 2>/dev/null || true
}

wsl_decrypt_file() {
    local input_file="$1"
    local win_path

    if [[ ! -f "$input_file" ]]; then
        echo ""
        return 0
    fi
    win_path=$(wslpath -w "$input_file" 2>/dev/null)
    if [[ -z "$win_path" ]]; then
        echo ""
        return 0
    fi
    powershell.exe -NoProfile -Command "
        Add-Type -AssemblyName System.Security
        \$bytes = [IO.File]::ReadAllBytes('${win_path}')
        \$plain = [Security.Cryptography.ProtectedData]::Unprotect(\$bytes, \$null, 'CurrentUser')
        [Text.Encoding]::UTF8.GetString(\$plain)
    " 2>/dev/null | tr -d '\r'
}

wsl_delete_file() {
    local input_file="$1"
    local win_path

    if [[ ! -f "$input_file" ]]; then
        return 0
    fi
    win_path=$(wslpath -w "$input_file" 2>/dev/null)
    if [[ -z "$win_path" ]]; then
        rm -f "$input_file"
        return 0
    fi
    powershell.exe -NoProfile -Command "Remove-Item -LiteralPath '${win_path}' -Force" >/dev/null 2>&1 || true
}

global_credentials_read() {
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            local service
            service=$(current_macos_global_service)
            if [[ -n "$service" ]]; then
                security find-generic-password -s "$service" -w 2>/dev/null || echo ""
            else
                echo ""
            fi
            ;;
        linux)
            secret-tool lookup service "$LEGACY_LINUX_SERVICE" type "active-credentials" 2>/dev/null || echo ""
            ;;
        wsl)
            wsl_decrypt_file "$(wsl_store_dir "$WSL_STORE_DIR_NAME")/$WSL_ACTIVE_STORE_BASENAME"
            ;;
        *)
            echo ""
            ;;
    esac
}

global_credentials_write() {
    local credentials="$1"
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            local service
            service=$(current_macos_global_service)
            if [[ -z "$service" ]]; then
                service="Claude Code-credentials"
            fi
            security add-generic-password -U -s "$service" -a "$USER" -w "$credentials" >/dev/null 2>&1
            ;;
        linux)
            printf '%s' "$credentials" | secret-tool store --label="Claude Code Active Credentials" \
                service "$LEGACY_LINUX_SERVICE" type "active-credentials" >/dev/null 2>&1
            ;;
        wsl)
            wsl_encrypt_to_file "$credentials" "$(wsl_store_dir "$WSL_STORE_DIR_NAME")/$WSL_ACTIVE_STORE_BASENAME"
            ;;
        *)
            return 1
            ;;
    esac
}

stored_account_credentials_read() {
    local account_id="$1"
    local email="$2"
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security find-generic-password -s "claude-switch-v2-account-${account_id}" -a "$email" -w 2>/dev/null || echo ""
            ;;
        linux)
            secret-tool lookup service "$LINUX_STORE_SERVICE" type "account-credentials" account_id "$account_id" email "$email" 2>/dev/null || echo ""
            ;;
        wsl)
            wsl_decrypt_file "$(wsl_store_dir "$WSL_STORE_DIR_NAME")/account-${account_id}.enc"
            ;;
        *)
            echo ""
            ;;
    esac
}

stored_account_credentials_write() {
    local account_id="$1"
    local email="$2"
    local credentials="$3"
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security add-generic-password -U -s "claude-switch-v2-account-${account_id}" -a "$email" -w "$credentials" >/dev/null 2>&1
            ;;
        linux)
            printf '%s' "$credentials" | secret-tool store --label="claude-switch v2 ${email}" \
                service "$LINUX_STORE_SERVICE" type "account-credentials" account_id "$account_id" email "$email" >/dev/null 2>&1
            ;;
        wsl)
            wsl_encrypt_to_file "$credentials" "$(wsl_store_dir "$WSL_STORE_DIR_NAME")/account-${account_id}.enc"
            ;;
        *)
            return 1
            ;;
    esac
}

stored_account_credentials_delete() {
    local account_id="$1"
    local email="$2"
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security delete-generic-password -s "claude-switch-v2-account-${account_id}" -a "$email" >/dev/null 2>&1 || true
            ;;
        linux)
            secret-tool clear service "$LINUX_STORE_SERVICE" type "account-credentials" account_id "$account_id" email "$email" >/dev/null 2>&1 || true
            ;;
        wsl)
            wsl_delete_file "$(wsl_store_dir "$WSL_STORE_DIR_NAME")/account-${account_id}.enc"
            ;;
    esac
}

legacy_account_credentials_read() {
    local legacy_number="$1"
    local email="$2"
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-Account-${legacy_number}-${email}" -w 2>/dev/null || echo ""
            ;;
        linux)
            secret-tool lookup service "$LEGACY_LINUX_SERVICE" account "$legacy_number" email "$email" 2>/dev/null || echo ""
            ;;
        wsl)
            wsl_decrypt_file "$(wsl_store_dir "$LEGACY_WSL_STORE_DIR_NAME")/account-${legacy_number}-${email}.enc"
            ;;
        *)
            echo ""
            ;;
    esac
}

backend_requirements_for() {
    local command_name="$1"
    case "$command_name" in
        add|switch|status|whoami|import-legacy)
            ;;
        *)
            return 0
            ;;
    esac

    case "$(detect_platform)" in
        linux)
            require_command secret-tool || return 1
            ;;
        wsl)
            require_command powershell.exe || return 1
            require_command wslpath || return 1
            ;;
    esac
    return 0
}
