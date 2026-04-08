in_container() {
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

detect_platform() {
    if [[ -n "$PLATFORM_CACHE" ]]; then
        echo "$PLATFORM_CACHE"
        return 0
    fi
    case "$(uname -s)" in
        Darwin) PLATFORM_CACHE="macos" ;;
        Linux)
            if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
                PLATFORM_CACHE="wsl"
            else
                PLATFORM_CACHE="linux"
            fi
            ;;
        *) PLATFORM_CACHE="unknown" ;;
    esac
    echo "$PLATFORM_CACHE"
}

iso8601_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

error() {
    echo "Error: $*" >&2
}

warn() {
    echo "Warning: $*" >&2
}

sanitize_slug() {
    local value="$1"
    value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')
    if [[ -z "$value" ]]; then
        value="item"
    fi
    echo "$value"
}

validate_json_file() {
    local file="$1"
    jq . "$file" >/dev/null 2>&1
}

validate_email() {
    local email="$1"
    [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

validate_alias() {
    local alias="$1"
    if [[ ! "$alias" =~ ^[A-Za-z0-9_-]+$ ]]; then
        return 1
    fi
    if [[ "$alias" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if validate_email "$alias"; then
        return 1
    fi
    return 0
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Required command '$cmd' not found"
        return 1
    fi
    return 0
}

ensure_dir_secure() {
    local dir="$1"
    mkdir -p "$dir"
    chmod 700 "$dir"
}

write_json() {
    local file="$1"
    local content="$2"
    local tmp

    tmp=$(mktemp "${file}.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    if ! jq . "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        error "Generated invalid JSON for $file"
        return 1
    fi
    chmod 600 "$tmp"
    mv "$tmp" "$file"
}

copy_json_file_secure() {
    local src="$1"
    local dest="$2"
    local content
    if [[ ! -f "$src" ]]; then
        error "Missing JSON file: $src"
        return 1
    fi
    if ! validate_json_file "$src"; then
        error "Invalid JSON in $src"
        return 1
    fi
    content=$(<"$src")
    write_json "$dest" "$content"
}

copy_tree_secure() {
    local src="$1"
    local dest="$2"
    mkdir -p "$dest"
    if [[ -d "$src" ]]; then
        cp -R "$src"/. "$dest"/
    fi
    find "$dest" -type d -exec chmod 700 {} + 2>/dev/null || true
    find "$dest" -type f -exec chmod 600 {} + 2>/dev/null || true
}

check_bash_version() {
    local version
    version=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    if ! awk -v ver="$version" 'BEGIN { exit (ver >= 4.4 ? 0 : 1) }'; then
        error "Bash 4.4+ required (found $version)"
        return 1
    fi
    return 0
}

state_dirs_init() {
    ensure_dir_secure "$STATE_DIR"
    ensure_dir_secure "$CONFIGS_DIR"
    ensure_dir_secure "$PROFILES_DIR"
}

manifest_exists() {
    [[ -f "$MANIFEST_FILE" ]]
}

legacy_state_exists() {
    [[ -f "$LEGACY_SEQUENCE_FILE" ]]
}

manifest_default_json() {
    local now
    now=$(iso8601_now)
    jq -n --arg now "$now" '
        {
            schemaVersion: 2,
            createdAt: $now,
            lastUpdated: $now,
            importedLegacy: false,
            activeAccountId: null,
            order: [],
            accounts: {}
        }
    '
}

manifest_init_empty() {
    state_dirs_init
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        write_json "$MANIFEST_FILE" "$(manifest_default_json)"
    fi
}

manifest_assert_valid() {
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        error "No v2 state found"
        return 1
    fi
    if ! validate_json_file "$MANIFEST_FILE"; then
        error "Invalid JSON in $MANIFEST_FILE"
        return 1
    fi
    if ! jq -e '.schemaVersion == 2 and (.accounts | type == "object") and (.order | type == "array")' "$MANIFEST_FILE" >/dev/null 2>&1; then
        error "Unsupported or invalid manifest format"
        return 1
    fi
    return 0
}

manifest_account_count() {
    if ! manifest_exists; then
        echo "0"
        return 0
    fi
    jq -r '.order | length' "$MANIFEST_FILE" 2>/dev/null || echo "0"
}

get_claude_config_path() {
    local primary="$HOME/.claude/.claude.json"
    local fallback="$HOME/.claude.json"

    if [[ -f "$primary" ]] && jq -e '.oauthAccount' "$primary" >/dev/null 2>&1; then
        echo "$primary"
        return 0
    fi
    echo "$fallback"
}

read_current_global_email() {
    local config
    config=$(get_claude_config_path)
    if [[ ! -f "$config" ]]; then
        echo "none"
        return 0
    fi
    if ! validate_json_file "$config"; then
        echo "none"
        return 0
    fi
    jq -r '.oauthAccount.emailAddress // "none"' "$config" 2>/dev/null
}

current_oauth_uuid() {
    local config
    config=$(get_claude_config_path)
    if [[ ! -f "$config" ]]; then
        echo ""
        return 0
    fi
    jq -r '.oauthAccount.accountUuid // empty' "$config" 2>/dev/null
}

generate_account_id() {
    local email="$1"
    printf 'acct-%s-%04d-%s\n' "$(date -u +%Y%m%d%H%M%S)" "$RANDOM" "$(sanitize_slug "$email")"
}

pretty_path() {
    local path="$1"
    if [[ "$path" == "$HOME"* ]]; then
        echo "~${path#"$HOME"}"
    else
        echo "$path"
    fi
}

link_shared_user_scope_into_profile() {
    local profile_dir="$1"
    local source_root="$HOME/.claude"
    local item source target

    for item in settings.json agents commands hooks skills plugins agent-memory; do
        source="$source_root/$item"
        target="$profile_dir/$item"

        if [[ ! -e "$source" ]]; then
            continue
        fi

        if [[ -d "$source" ]]; then
            if [[ -L "$target" ]]; then
                if [[ "$(readlink "$target")" == "$source" ]]; then
                    continue
                fi
                rm -f "$target"
            elif [[ ! -e "$target" ]]; then
                ln -s "$source" "$target"
                continue
            elif [[ ! -d "$target" ]]; then
                continue
            fi

            local source_item target_item
            for source_item in "$source"/* "$source"/.[!.]* "$source"/..?*; do
                [[ -e "$source_item" ]] || continue
                target_item="$target/$(basename "$source_item")"
                if [[ -L "$target_item" ]]; then
                    if [[ "$(readlink "$target_item")" == "$source_item" ]]; then
                        continue
                    fi
                    rm -f "$target_item"
                elif [[ -e "$target_item" ]]; then
                    continue
                fi
                ln -s "$source_item" "$target_item"
            done
            continue
        fi

        if [[ -L "$target" ]]; then
            if [[ "$(readlink "$target")" == "$source" ]]; then
                continue
            fi
            rm -f "$target"
        elif [[ -e "$target" ]]; then
            continue
        fi

        ln -s "$source" "$target"
    done
}

claude_project_store_key() {
    local project_path="${1:-$(pwd)}"
    printf '%s' "$project_path" | sed 's|/|-|g'
}

link_current_project_memory_into_profile() {
    local profile_dir="$1"
    local project_key source_dir target_dir target_parent

    project_key=$(claude_project_store_key "$(pwd)")
    source_dir="$HOME/.claude/projects/$project_key/memory"
    if [[ ! -d "$source_dir" ]]; then
        return 0
    fi

    target_dir="$profile_dir/projects/$project_key/memory"
    target_parent=$(dirname "$target_dir")
    mkdir -p "$target_parent"
    chmod 700 "$profile_dir/projects" "$target_parent" 2>/dev/null || true

    if [[ -L "$target_dir" ]]; then
        if [[ "$(readlink "$target_dir")" == "$source_dir" ]]; then
            return 0
        fi
        rm -f "$target_dir"
    elif [[ ! -e "$target_dir" ]]; then
        ln -s "$source_dir" "$target_dir"
        return 0
    elif [[ ! -d "$target_dir" ]]; then
        return 0
    fi

    local source_item target_item
    for source_item in "$source_dir"/* "$source_dir"/.[!.]* "$source_dir"/..?*; do
        [[ -e "$source_item" ]] || continue
        target_item="$target_dir/$(basename "$source_item")"
        if [[ -L "$target_item" ]]; then
            if [[ "$(readlink "$target_item")" == "$source_item" ]]; then
                continue
            fi
            rm -f "$target_item"
        elif [[ -e "$target_item" ]]; then
            continue
        fi
        ln -s "$source_item" "$target_item"
    done
}

pause_for_enter() {
    echo ""
    echo -n "Press Enter to continue..." >&2
    IFS= read -r _ || true
}

prompt_line() {
    local prompt="$1"
    local reply
    echo -n "$prompt" >&2
    IFS= read -r reply || true
    echo "$reply"
}

prompt_yes_no() {
    local prompt="$1"
    local reply
    echo -n "$prompt [y/N] " >&2
    IFS= read -r reply || true
    [[ "$reply" == "y" || "$reply" == "Y" ]]
}

clear_screen() {
    if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
        clear
    fi
}

spinner_start() {
    local message="$1"
    (
        while true; do
            local char
            for char in "${SPINNER_CHARS[@]}"; do
                printf '\r%s %s' "$char" "$message"
                sleep 0.1
            done
        done
    ) &
    SPINNER_PID=$!
}

spinner_stop() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf '\r\033[K'
    fi
}

format_duration() {
    local seconds="$1"
    if [[ "$seconds" -le 0 ]]; then
        echo "now"
        return 0
    fi
    local days hours minutes
    local parts=()

    days=$((seconds / 86400))
    hours=$(((seconds % 86400) / 3600))
    minutes=$(((seconds % 3600) / 60))
    [[ "$days" -gt 0 ]] && parts+=("${days}d")
    [[ "$hours" -gt 0 ]] && parts+=("${hours}h")
    [[ "$days" -eq 0 && "$minutes" -gt 0 ]] && parts+=("${minutes}m")
    printf '%s\n' "${parts[*]}"
}

parse_reset_time_epoch() {
    local ts="$1"
    local epoch=""
    epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null) || \
    epoch=$(date -d "$ts" +%s 2>/dev/null) || epoch=""
    echo "$epoch"
}

needs_sudo() {
    local dir="$1"
    [[ ! -w "$dir" ]]
}

run_maybe_sudo() {
    local dir="$1"
    shift
    if needs_sudo "$dir"; then
        sudo "$@"
    else
        "$@"
    fi
}
