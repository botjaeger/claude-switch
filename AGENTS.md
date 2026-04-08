# AGENTS.md

This file provides guidance to Codex when working in this repository.

## Project Overview

`claude-switch` is a cross-platform multi-account switcher for Claude Code and Claude Desktop workflows.

Current v2 shape:

- modular Bash source lives in `src/`
- `scripts/build.sh` bundles the release artifact into `claude-switch.sh`
- the CLI supports `add <email> [alias]`, `run <email|alias>`, `switch <email|alias>`, `list`, `status`, `whoami`, `alias`, `unalias`, `remove`, `import-legacy`, `install`, `uninstall`, `version`, and `help`
- running `claude-switch` with no arguments in a TTY opens the interactive launcher

Requirements:

- Bash 4.4+
- `jq`
- Linux: `libsecret-tools`
- WSL: `powershell.exe` and `wslpath`

## Commands

```bash
# Rebuild the generated release script after editing src/*
./scripts/build.sh

# Syntax check
bash -n claude-switch.sh

# Show current CLI help
./claude-switch.sh help

# Install to a test prefix
./claude-switch.sh install --prefix /tmp/test-bin

# Core integration tests
bash tests/test-run-command.sh ./claude-switch.sh
bash tests/test-add-command.sh ./claude-switch.sh
bash tests/test-interactive-shell.sh ./claude-switch.sh
bash tests/test-import-legacy.sh ./claude-switch.sh
bash tests/test-alias-lifecycle.sh ./claude-switch.sh
bash tests/test-install-uninstall.sh ./claude-switch.sh
```

CI in `.github/workflows/ci.yml` runs:

- bundle validation (`./scripts/build.sh` then `git diff --exit-code -- claude-switch.sh`)
- `bash -n claude-switch.sh`
- `shellcheck claude-switch.sh`
- Linux shell integration tests
- macOS install/help/uninstall plus keychain round-trip
- WSL syntax/install/help/uninstall plus PowerShell and `wslpath` interop

## Conventions

- Edit `src/*`, not the generated `claude-switch.sh`.
- If you change `src/*`, rebuild `claude-switch.sh` with `./scripts/build.sh`.
- The code uses `set -euo pipefail`.
- `VERSION` lives in `src/00-header.sh` and is reflected into the generated bundle.
- Never write JSON directly to target files. Use:
  - `write_json()` for JSON content
  - `copy_json_file_secure()` for copying JSON files
  - `state_write_manifest_jq()` for manifest mutations
- Files should be `600`, directories `700`.
- Keep legacy flag syntax rejected in v2. Old `--run` / `--switch` style commands should map to migration hints, not become first-class behavior again.
- `add` is email-first: `add <email> [alias]`. `run`, `switch`, `remove`, and `alias` accept either email or alias.

## Architecture

### Source layout

- `src/00-header.sh`
  - constants, paths, version, spinner characters
- `src/10-common.sh`
  - platform detection, validation helpers, secure file helpers, prompt helpers
  - links shared `~/.claude` user-scoped surfaces into isolated profiles
  - links current-project Claude memory into isolated profiles
- `src/20-backends.sh`
  - credential backend implementations
  - macOS: Keychain
  - Linux: `secret-tool`
  - WSL: DPAPI-encrypted files via `powershell.exe`
- `src/30-store.sh`
  - v2 state access and manifest mutations
  - legacy import from `~/.claude-switch-backup`
- `src/40-commands.sh`
  - command implementations
  - `run` launches Claude with `CLAUDE_CONFIG_DIR` pointed at an isolated per-account profile
  - `switch` rewrites the global Claude auth/config used by Desktop and default-profile workflows
- `src/50-launcher.sh`
  - boxed interactive terminal launcher shown by bare `claude-switch` in a TTY
- `src/99-main.sh`
  - usage, legacy flag rejection, root guards, dispatch

### State layout

v2 state lives under:

```text
~/.claude-switch/
  manifest.json
  configs/
    <account-id>.json
  profiles/
    <account-id>-<email-slug>/
```

Important details:

- `manifest.json` is the source of truth for managed accounts, aliases, order, and active account tracking
- account lookup is email-first, then alias (`state_find_account_id`)
- legacy data is imported from `~/.claude-switch-backup/`
- stored credentials are kept in OS-native backends, not in the manifest

### Shared vs isolated behavior in `run`

`run` isolates account auth, but intentionally shares parts of the normal Claude environment:

- shared into the isolated profile:
  - `~/.claude/settings.json`
  - `~/.claude/agents`
  - `~/.claude/commands`
  - `~/.claude/hooks`
  - `~/.claude/skills`
  - `~/.claude/plugins`
  - `~/.claude/agent-memory`
  - current-project memory under `~/.claude/projects/<project>/memory`
- isolated per profile:
  - auth
  - `.claude.json`
  - per-profile runtime/session state under `~/.claude-switch/profiles/...`

## Testing Notes

- Prefer the shell integration tests in `tests/` over ad hoc manual verification.
- `tests/test-lib.sh` creates disposable v2 homes and fixtures used by the other tests.
- `tests/test-run-command.sh` covers:
  - isolated profile path wiring
  - shared settings/agents/project-memory linking
  - `--exclude-local-settings` vs default `user,project,local`
  - pre/post auth mismatch handling
  - legacy flag rejection
- `tests/test-add-command.sh` covers:
  - forced logout + Claude login flow
  - auth code handoff messaging
  - requested email matching the authenticated email
  - alias persistence on add
- WSL DPAPI round-trip is intentionally not exercised in GitHub Actions because hosted Windows runners do not expose a normal loaded user profile for DPAPI `CurrentUser`.
