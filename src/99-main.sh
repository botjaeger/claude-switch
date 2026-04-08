legacy_command_hint() {
    local arg="$1"
    case "$arg" in
        --add) echo "claude-switch add <email> [alias]" ;;
        --add-account) echo "claude-switch add <email> [alias]" ;;
        --remove-account) echo "claude-switch remove <email|alias>" ;;
        --list) echo "claude-switch list" ;;
        --run) echo "claude-switch run <email|alias>" ;;
        --switch) echo "claude-switch switch <email|alias>" ;;
        --status|--whoami) echo "claude-switch status" ;;
        --alias) echo "claude-switch alias <email|alias> <name>" ;;
        --unalias) echo "claude-switch unalias <alias>" ;;
        --install) echo "claude-switch install" ;;
        --uninstall) echo "claude-switch uninstall" ;;
        --version) echo "claude-switch version" ;;
        --help) echo "claude-switch help" ;;
        *)
            echo ""
            ;;
    esac
}

show_usage() {
    echo "claude-switch v$VERSION"
    echo "Usage: claude-switch <command> [args]"
    echo ""
    echo "Commands:"
    echo "  add <email> [alias]              Run Claude Code login and add a managed account"
    echo "  list                             List managed accounts"
    echo "  run <email|alias> [-- ...]       Launch the claude CLI in an isolated profile"
    echo "  switch <email|alias>             Switch the global Claude account"
    echo "  status, whoami                   Show current account info"
    echo "  alias <email|alias> <name>       Set an alias"
    echo "  unalias <alias>                  Remove an alias"
    echo "  remove <email|alias>             Remove an account"
    echo "  import-legacy                    Import legacy ~/.claude-switch-backup data"
    echo "  install [--prefix /path]         Install claude-switch"
    echo "  uninstall [--prefix /path]       Uninstall claude-switch"
    echo "  version                          Show the current version"
    echo "  help                             Show this help"
    echo ""
    echo "Options:"
    echo "  -y, --yes                        Skip confirmation prompts where supported"
    echo "  --exclude-local-settings         With run, ignore Claude's local repo settings source"
    echo "  --include-local-settings         Accepted for compatibility; local is now included by default"
    echo ""
    echo "Interactive:"
    echo "  Run 'claude-switch' with no arguments in a TTY to open the launcher."
    echo ""
    echo "Examples:"
    echo "  claude-switch"
    echo "  claude-switch add alice@example.com work"
    echo "  claude-switch import-legacy"
    echo "  claude-switch run work -- --model sonnet"
    echo "  claude-switch switch work"
}

main() {
    local args=()
    local arg command legacy_hint

    for arg in "$@"; do
        case "$arg" in
            -y|--yes)
                GLOBAL_YES=true
                ;;
            *)
                args+=("$arg")
                ;;
        esac
    done
    set -- "${args[@]+"${args[@]}"}"

    check_bash_version || return 1

    if [[ "${1:-}" == --* ]]; then
        legacy_hint=$(legacy_command_hint "$1")
        if [[ -n "$legacy_hint" ]]; then
            error "Legacy flag-style syntax is no longer supported in v2."
            echo "Use: $legacy_hint" >&2
            return 1
        fi
    fi

    if [[ $# -eq 0 ]]; then
        if [[ $EUID -eq 0 ]] && ! in_container && should_start_interactive_launcher; then
            error "Do not run this script as root (unless running in a container)"
            return 1
        fi
        if should_start_interactive_launcher; then
            command_launcher
        else
            show_usage
        fi
        return $?
    fi

    if [[ $EUID -eq 0 ]] && ! in_container; then
        case "$1" in
            help|version|install|uninstall)
                ;;
            *)
                error "Do not run this script as root (unless running in a container)"
                return 1
                ;;
        esac
    fi

    command="$1"
    shift
    check_command_backend_requirements "$command" || return 1
    run_subcommand "$command" "$@"
}

main "$@"
