should_start_interactive_launcher() {
    if [[ "$INTERACTIVE_FORCE" == "1" ]]; then
        return 0
    fi
    [[ -t 0 && -t 1 ]]
}

launcher_supports_color() {
    [[ -t 1 ]] || return 1
    [[ -z "${NO_COLOR:-}" ]] || return 1
    [[ "${TERM:-}" != "dumb" ]]
}

launcher_theme_init() {
    if launcher_supports_color; then
        LAUNCHER_RESET=$'\033[0m'
        LAUNCHER_BOLD=$'\033[1m'
        LAUNCHER_TITLE=$'\033[38;2;210;216;224m'
        LAUNCHER_MUTED=$'\033[38;2;126;136;149m'
        LAUNCHER_LINE=$'\033[38;2;74;84;100m'
        LAUNCHER_ACCENT=$'\033[38;2;168;180;197m'
        LAUNCHER_ACCENT_ALT=$'\033[38;2;144;156;174m'
        LAUNCHER_ACTIVE=$'\033[38;2;228;233;239m'
    else
        LAUNCHER_RESET=""
        LAUNCHER_BOLD=""
        LAUNCHER_TITLE=""
        LAUNCHER_MUTED=""
        LAUNCHER_LINE=""
        LAUNCHER_ACCENT=""
        LAUNCHER_ACCENT_ALT=""
        LAUNCHER_ACTIVE=""
    fi
}

launcher_layout_init() {
    local cols
    cols="${COLUMNS:-}"
    if [[ -z "$cols" ]] && command -v tput >/dev/null 2>&1; then
        cols=$(tput cols 2>/dev/null || echo "")
    fi
    if [[ -z "$cols" || "$cols" -lt 68 ]]; then
        cols=96
    fi

    LAUNCHER_WIDTH=$((cols - 4))
    if [[ "$LAUNCHER_WIDTH" -gt 100 ]]; then
        LAUNCHER_WIDTH=100
    fi
    if [[ "$LAUNCHER_WIDTH" -lt 64 ]]; then
        LAUNCHER_WIDTH=64
    fi

    LAUNCHER_INNER_WIDTH=$((LAUNCHER_WIDTH - 2))
    LAUNCHER_MARGIN=$(((cols - LAUNCHER_WIDTH) / 2))
    if [[ "$LAUNCHER_MARGIN" -lt 0 ]]; then
        LAUNCHER_MARGIN=0
    fi
}

launcher_repeat() {
    local char="$1"
    local count="$2"
    local out=""
    while [[ "${#out}" -lt "$count" ]]; do
        out+="$char"
    done
    printf '%s' "${out:0:$count}"
}

launcher_trim() {
    local text="$1"
    local width="$2"
    if [[ "${#text}" -le "$width" ]]; then
        printf '%s' "$text"
        return 0
    fi
    if [[ "$width" -le 3 ]]; then
        printf '%s' "${text:0:$width}"
        return 0
    fi
    printf '%s...' "${text:0:$((width - 3))}"
}

launcher_margin_pad() {
    printf '%*s' "$LAUNCHER_MARGIN" ""
}

launcher_frame_top() {
    printf '%s%b┌%s┐%b\n' \
        "$(launcher_margin_pad)" \
        "$LAUNCHER_LINE" \
        "$(launcher_repeat '─' "$LAUNCHER_INNER_WIDTH")" \
        "$LAUNCHER_RESET"
}

launcher_frame_bottom() {
    printf '%s%b└%s┘%b\n' \
        "$(launcher_margin_pad)" \
        "$LAUNCHER_LINE" \
        "$(launcher_repeat '─' "$LAUNCHER_INNER_WIDTH")" \
        "$LAUNCHER_RESET"
}

launcher_frame_row() {
    local text="$1"
    local align="${2:-left}"
    local tone="${3:-}"
    local plain pad left_pad right_pad padded

    plain=$(launcher_trim "$text" "$LAUNCHER_INNER_WIDTH")
    pad=$((LAUNCHER_INNER_WIDTH - ${#plain}))
    left_pad=0
    right_pad="$pad"

    if [[ "$align" == "center" ]]; then
        left_pad=$((pad / 2))
        right_pad=$((pad - left_pad))
    fi

    padded="$(printf '%*s%s%*s' "$left_pad" '' "$plain" "$right_pad" '')"
    printf '%s%b│%b%b%s%b%b│%b\n' \
        "$(launcher_margin_pad)" \
        "$LAUNCHER_LINE" "$LAUNCHER_RESET" \
        "$tone" "$padded" "$LAUNCHER_RESET" \
        "$LAUNCHER_LINE" "$LAUNCHER_RESET"
}

launcher_frame_empty() {
    launcher_frame_row ""
}

launcher_box_top() {
    local width="$1"
    local title="$2"
    local body label filler left_fill right_fill

    body=$((width - 2))
    label=" $title "
    if [[ "${#label}" -gt "$body" ]]; then
        label=" $(launcher_trim "$title" "$((body - 2))") "
    fi
    filler=$((body - ${#label}))
    left_fill=$((filler / 2))
    right_fill=$((filler - left_fill))
    printf '┌%s%s%s┐' \
        "$(launcher_repeat '─' "$left_fill")" \
        "$label" \
        "$(launcher_repeat '─' "$right_fill")"
}

launcher_box_bottom() {
    local width="$1"
    printf '└%s┘' "$(launcher_repeat '─' "$((width - 2))")"
}

launcher_box_row() {
    local width="$1"
    local text="$2"
    local body plain right_pad

    body=$((width - 4))
    plain=$(launcher_trim "$text" "$body")
    right_pad=$((body - ${#plain}))
    printf '│ %s%*s │' "$plain" "$right_pad" ''
}

launcher_box_rule() {
    local width="$1"
    printf '│ %s │' "$(launcher_repeat '─' "$((width - 4))")"
}

launcher_prompt() {
    printf '%b›%b ' "$LAUNCHER_TITLE$LAUNCHER_BOLD" "$LAUNCHER_RESET"
}

launcher_status_line() {
    local managed_count workspace
    managed_count=$(manifest_account_count)
    workspace=$(pretty_path "$(pwd)")
    printf '%s%bclaude-switch v%s%b %b•%b %s profile%s %b•%b %s\n' \
        "$(launcher_margin_pad)" \
        "$LAUNCHER_MUTED" "$VERSION" "$LAUNCHER_RESET" \
        "$LAUNCHER_LINE" "$LAUNCHER_RESET" \
        "$managed_count" "$( [[ "$managed_count" == "1" ]] && echo "" || echo "s" )" \
        "$LAUNCHER_LINE" "$LAUNCHER_RESET" \
        "$workspace"
}

launcher_show_summary_box() {
    local current_email="$1"
    local managed_count="$2"
    local platform_name="$3"
    local workspace="$4"
    local box_width

    box_width=$((LAUNCHER_INNER_WIDTH - 22))
    if [[ "$box_width" -gt 62 ]]; then
        box_width=62
    fi
    if [[ "$box_width" -lt 42 ]]; then
        box_width=$((LAUNCHER_INNER_WIDTH - 4))
    fi

    launcher_frame_row "$(launcher_box_top "$box_width" "session")" center "$LAUNCHER_LINE"
    launcher_frame_row "$(launcher_box_row "$box_width" "desktop   $current_email")" center
    launcher_frame_row "$(launcher_box_row "$box_width" "profiles  $managed_count managed")" center
    launcher_frame_row "$(launcher_box_row "$box_width" "platform  $platform_name")" center
    launcher_frame_row "$(launcher_box_row "$box_width" "workspace $workspace")" center
    launcher_frame_row "$(launcher_box_bottom "$box_width")" center "$LAUNCHER_LINE"
}

launcher_show_accounts() {
    local box_width active_id rows idx

    box_width=$((LAUNCHER_INNER_WIDTH - 10))
    if [[ "$box_width" -lt 56 ]]; then
        box_width=$((LAUNCHER_INNER_WIDTH - 4))
    fi

    launcher_frame_row "$(launcher_box_top "$box_width" "managed profiles")" center "$LAUNCHER_LINE"

    if ! manifest_exists || [[ "$(manifest_account_count)" -eq 0 ]]; then
        launcher_frame_row "$(launcher_box_row "$box_width" "no managed profiles yet")" center "$LAUNCHER_TITLE"
        launcher_frame_row "$(launcher_box_row "$box_width" "start with: add you@example.com work")" center "$LAUNCHER_MUTED"
        launcher_frame_row "$(launcher_box_bottom "$box_width")" center "$LAUNCHER_LINE"
        return 0
    fi

    active_id=$(state_current_active_managed_id)
    mapfile -t rows < <(
        jq -r --arg active "$active_id" '
            .order[] as $id |
            .accounts[$id] |
            [
                (if $id == $active then "1" else "0" end),
                .email,
                (.alias // "")
            ] | @tsv
        ' "$MANIFEST_FILE"
    )

    for idx in "${!rows[@]}"; do
        local row_active email alias_name profile_title target state_label action_line detail_tone
        IFS=$'\t' read -r row_active email alias_name <<< "${rows[$idx]}"

        profile_title="$email"
        target="$email"
        if [[ -n "$alias_name" ]]; then
            profile_title="$alias_name"
            target="$alias_name"
        fi

        state_label="isolated profile"
        detail_tone="$LAUNCHER_MUTED"
        if [[ "$row_active" == "1" ]]; then
            state_label="desktop default"
            detail_tone="$LAUNCHER_ACCENT"
        fi

        action_line="$state_label • run $target • switch $target"
        launcher_frame_row "$(launcher_box_row "$box_width" "$profile_title")" center "$LAUNCHER_ACTIVE"
        if [[ -n "$alias_name" ]]; then
            launcher_frame_row "$(launcher_box_row "$box_width" "$email")" center "$LAUNCHER_MUTED"
        fi
        launcher_frame_row "$(launcher_box_row "$box_width" "$action_line")" center "$detail_tone"
        if [[ "$idx" -lt $((${#rows[@]} - 1)) ]]; then
            launcher_frame_row "$(launcher_box_rule "$box_width")" center "$LAUNCHER_LINE"
        fi
    done

    launcher_frame_row "$(launcher_box_bottom "$box_width")" center "$LAUNCHER_LINE"
}

launcher_show_banner() {
    local current_email managed_count platform_name workspace

    launcher_theme_init
    launcher_layout_init
    clear_screen
    current_email=$(read_current_global_email)
    if [[ "$current_email" == "none" ]]; then
        current_email="unmanaged"
    fi
    managed_count=$(manifest_account_count)
    platform_name=$(detect_platform)
    workspace=$(pretty_path "$(pwd)")

    launcher_frame_top
    launcher_frame_empty
    launcher_frame_row "claude-switch." center "$LAUNCHER_TITLE$LAUNCHER_BOLD"
    launcher_frame_row "launch Claude profiles from one terminal" center "$LAUNCHER_ACCENT"
    launcher_frame_row "$workspace" center "$LAUNCHER_MUTED"
    launcher_frame_empty
    launcher_show_summary_box "$current_email" "$managed_count" "$platform_name" "$workspace"
    launcher_frame_empty
    launcher_show_accounts
    launcher_frame_empty
    launcher_frame_row "[add] new account   [run profile] isolate   [switch profile] desktop" center "$LAUNCHER_ACCENT_ALT"
    launcher_frame_row "[list] inspect profiles   [help] reference   [clear] redraw   [q] quit" center "$LAUNCHER_MUTED"
    launcher_frame_bottom
    echo ""
}

launcher_show_help() {
    cat <<'EOF'
Switch:
  add <email> [alias]              Run Claude Code login and add a managed account
  run <email|alias> [-- ...]       Launch the claude CLI in an isolated profile
  switch <email|alias>             Switch the global Claude account

Manage:
  list                             List managed accounts
  alias <email|alias> <name>       Set an alias
  unalias <alias>                  Remove an alias
  remove <email|alias>             Remove an account

Inspect:
  status, whoami                   Show current account info
  import-legacy                    Import legacy ~/.claude-switch-backup data
  version                          Show the current version

Launcher:
  help                             Show this help
  clear                            Redraw the launcher
  quit                             Exit claude-switch
  /<command>                       Slash-prefixed commands also work
EOF
}

launcher_offer_legacy_import() {
    LAUNCHER_REDRAW_AFTER_IMPORT=0
    if manifest_exists || ! legacy_state_exists; then
        return 0
    fi
    LAUNCHER_REDRAW_AFTER_IMPORT=1
    echo ""
    echo "Legacy state detected at $(pretty_path "$LEGACY_BACKUP_DIR")."
    if prompt_yes_no "Import it into v2 now?"; then
        command_import_legacy || return 1
        pause_for_enter
    fi
    return 0
}

run_subcommand() {
    local command="$1"
    shift
    case "$command" in
        add) command_add "$@" ;;
        list) command_list "$@" ;;
        run) command_run "$@" ;;
        switch) command_switch "$@" ;;
        status|whoami) command_status ;;
        alias) command_alias "$@" ;;
        unalias) command_unalias "$@" ;;
        remove) command_remove_account "$@" ;;
        install) command_install "$@" ;;
        uninstall) command_uninstall "$@" ;;
        import-legacy) command_import_legacy "$@" ;;
        version)
            echo "claude-switch $VERSION"
            ;;
        help)
            show_usage
            ;;
        *)
            error "Unknown command '$command'"
            return 1
            ;;
    esac
}

launcher_execute_line() {
    local line="$1"
    local args=()
    local command

    read -r -a args <<< "$line"
    if [[ ${#args[@]} -eq 0 ]]; then
        return 0
    fi

    command="${args[0]}"
    if [[ "$command" == /* ]]; then
        command="${command#/}"
    fi

    case "$command" in
        quit|exit|q)
            return 10
            ;;
        clear|cls)
            launcher_show_banner
            return 0
            ;;
        help)
            launcher_show_help
            return 0
            ;;
        *)
            if run_subcommand "$command" "${args[@]:1}"; then
                return 0
            fi
            local status=$?
            echo ""
            echo "Command exited with status $status."
            return 0
            ;;
    esac
}

command_launcher() {
    launcher_show_banner
    launcher_offer_legacy_import || return 1
    if [[ "${LAUNCHER_REDRAW_AFTER_IMPORT:-0}" == "1" ]]; then
        launcher_show_banner
    fi
    while true; do
        local line
        launcher_status_line
        line=$(prompt_line "$(launcher_prompt)")
        if ! launcher_execute_line "$line"; then
            local status=$?
            if [[ "$status" -eq 10 ]]; then
                echo ""
                return 0
            fi
            return "$status"
        fi
        echo ""
    done
}
