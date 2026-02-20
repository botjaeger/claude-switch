# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

claude-switch is a multi-account switcher for Claude Code. It's a single Bash script (`claude-switch.sh`) that manages and switches between multiple Claude Code accounts from the command line. Requires Bash 4.4+ and `jq`.

## Commands

```bash
# Syntax check (this is the lint step in CI)
bash -n claude-switch.sh

# Run locally
./claude-switch.sh --help

# Install to a test prefix
./claude-switch.sh --install --prefix /tmp/test-bin
```

There are no unit tests beyond the CI workflow (`.github/workflows/ci.yml`), which runs a syntax check then platform-specific integration tests on all three platforms (macOS, Linux, WSL). Tests cover install/uninstall, keychain round-trip (macOS), libsecret round-trip (Linux), and PowerShell/wslpath interop (WSL).

## Conventions

- The script uses `set -euo pipefail`. All top-level constants are `readonly`.
- `VERSION` at the top of the script must be updated for releases.
- All JSON writes must go through `write_json()` (temp file, `jq` validation, `chmod 600`, atomic rename). Never write JSON directly to the target path.
- Files are created with `600` permissions, directories with `700`.

## Architecture

The entire tool is a single script with this structure:

- **Platform detection** (`detect_platform`): Returns `macos`, `linux`, `wsl`, or `unknown`. Result is cached in `_PLATFORM` to avoid repeated `uname` subshells. Container environments are also detected.
- **Credential backends**: Three platform-specific implementations for reading/writing/deleting credentials:
  - macOS: `security` CLI (Keychain) — service names like `Claude Code-Account-<N>-<email>`
  - Linux: `secret-tool` (libsecret) — service `claude-code` with account/email attributes
  - WSL: `powershell.exe` with DPAPI — encrypted files in `%USERPROFILE%\.claude-switch\`
- **Account registry**: `~/.claude-switch-backup/sequence.json` tracks accounts, sequence order, active account, and aliases. Config backups are stored as JSON files in `~/.claude-switch-backup/configs/`.
- **Config path resolution** (`get_claude_config_path`): Checks `~/.claude/.claude.json` first, falls back to `~/.claude.json`.
- **Account resolution** (`resolve_account_identifier`): Accepts email or alias, returns account number.
- **Switching** (`perform_switch`): Saves current session (config + credentials), restores target session, updates `sequence.json`. On macOS, handles service name migration between keychain entries.
- **CLI dispatch**: `main()` pre-scans for `-y`/`--yes`, handles `--install`/`--uninstall`/`--version` before dependency checks, then dispatches remaining commands including `--status`/`--whoami`.
