# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

claude-switch is a cross-platform multi-account switcher for Claude Code. `claude-switch run` launches the `claude` CLI against an isolated per-account profile (via `CLAUDE_CONFIG_DIR`) without touching the global Claude Desktop auth, while `claude-switch switch` rewrites the global auth/config. Requires Bash 4.4+ and `jq`; Linux additionally needs `libsecret-tools`, WSL needs `powershell.exe` + `wslpath`.

## Build Pipeline — Important

The user-facing `claude-switch.sh` at the repo root is **generated**. Never hand-edit it. Source of truth lives in `src/`, and `scripts/build.sh` concatenates the modules (in numeric-prefix order) into `claude-switch.sh`:

```
src/00-header.sh   # VERSION, constants, globals, EXIT trap
src/10-common.sh   # platform detect, validators, write_json, shared-profile symlinking, spinner
src/20-backends.sh # macOS/Linux/WSL credential read/write/delete + active-credential store
src/30-store.sh    # manifest.json helpers, legacy import command
src/40-commands.sh # add/list/run/switch/status/alias/remove/install/uninstall/update
src/50-launcher.sh # framed interactive TTY launcher
src/99-main.sh     # show_usage, legacy-flag rejection, main() dispatcher
```

After editing anything under `src/`, always rebuild before committing — CI's lint job runs `./scripts/build.sh` and then `git diff --exit-code -- claude-switch.sh`, so an un-rebuilt bundle fails CI. `VERSION` in `src/00-header.sh` is managed by release-please via the `# x-release-please-version` marker.

## Commands

```bash
# Rebuild the bundled script after any change in src/
./scripts/build.sh

# Lint (matches CI)
bash -n claude-switch.sh
shellcheck claude-switch.sh

# Run the whole integration suite against the built bundle
for t in tests/test-*.sh; do bash "$t" ./claude-switch.sh || break; done

# Run a single test (each test takes the script path as $1)
bash tests/test-run-command.sh ./claude-switch.sh
bash tests/test-add-command.sh ./claude-switch.sh

# Install to a disposable prefix (what CI uses)
bash claude-switch.sh install --prefix /tmp/ci-test
```

Tests are plain bash scripts that `source tests/test-lib.sh` for assertions and `make_v2_home` / `make_two_account_home` fixtures. They stub `claude`, `secret-tool`, and sometimes `uname` by prepending a temp dir to `PATH`, then exercise the real `claude-switch.sh` against a synthetic `$HOME`. CI's `test-linux` job runs them in order after lint (`.github/workflows/ci.yml`). macOS and WSL CI jobs only run install/uninstall + keychain/libsecret/DPAPI round-trips — they do not run the `tests/test-*.sh` suite.

## Conventions

- `set -euo pipefail` in every module; top-level constants are `readonly` and live in `src/00-header.sh`.
- **All JSON writes go through `write_json()`** (temp file → `jq` validate → `chmod 600` → atomic rename). Manifest mutations additionally use `state_write_manifest_jq` which wraps `jq`-in-place with the same temp+rename pattern. Never write JSON directly to a target path.
- Files are created with `600`, directories with `700` (`ensure_dir_secure`, `copy_tree_secure`).
- Platform detection is cached in `PLATFORM_CACHE` (not `_PLATFORM`) — use `detect_platform` rather than re-shelling `uname`.
- Shell-out errors are surfaced via `error`/`warn` (both to stderr) and non-zero return. Keep that convention — tests grep stderr for these messages.
- Legacy `--flag`-style CLI syntax (`--add`, `--run`, etc.) is intentionally rejected with a migration hint (`legacy_command_hint` in `src/99-main.sh`). Do not re-add flag-style entry points.

## Architecture

### State layout (v2)

```
~/.claude-switch/
  manifest.json                       # schemaVersion:2, accounts{}, order[], activeAccountId
  configs/<account-id>.json           # snapshot of .claude.json with oauthAccount
  profiles/<account-id>-<slug>/       # CLAUDE_CONFIG_DIR target used by `run`
```

`manifest.json` is the source of truth for account identity, ordering, aliases, and which account is currently active. Account IDs are stable strings (`acct-<ts>-<rand>-<slug>` for new adds, `legacy-<n>-<slug>` for imports) — **do not** treat them as numeric. All manifest reads and writes go through helpers in `src/30-store.sh`.

Legacy state lives at `~/.claude-switch-backup/sequence.json`. v2 never reads legacy state implicitly: if the manifest is missing but legacy exists, commands print a migration notice and `ensure_v2_ready_or_notice` returns 1 until the user runs `import-legacy`. The launcher has an interactive shortcut for this (`launcher_offer_legacy_import`).

### Credential backends (`src/20-backends.sh`)

Three flavors, all behind the same `global_credentials_{read,write}` / `stored_account_credentials_{read,write,delete}` API:

- **macOS**: `security` CLI. The *active* global credential uses either `Claude Code-credentials` or the older `Claude Code` service — `current_macos_global_service` probes for which one exists. Managed account credentials use a new v2 service, `claude-switch-v2-account-<id>`, keyed by email.
- **Linux**: `secret-tool` (libsecret). Active credentials use legacy service `claude-code` (unchanged for compatibility with Claude Code itself); managed account credentials use service `claude-switch-v2`.
- **WSL**: `powershell.exe` + DPAPI. Encrypted blobs live under `%USERPROFILE%\.claude-switch-v2\`, with the legacy dir `.claude-switch` still read for import.

`backend_requirements_for` gates commands that actually need a backend (`add`, `switch`, `status`, `whoami`, `import-legacy`) so that `help`, `version`, `install`, `uninstall`, `update`, and `list` still work on systems missing `secret-tool`/`powershell.exe`.

### `run` — isolated profiles with shared user scope

`command_run` is the most subtle command. It does **not** create a hermetic Claude home:

1. Ensures the per-account profile dir exists under `~/.claude-switch/profiles/…` with `700` perms.
2. `link_shared_user_scope_into_profile` symlinks the user-scope surfaces from `~/.claude/` into the profile: `settings.json`, `agents/`, `commands/`, `hooks/`, `skills/`, `plugins/`, `agent-memory/`. For directories, it links the dir itself when the target doesn't exist, otherwise merges by per-entry symlinks — so adding a single new agent works even if the target dir already has content.
3. `link_current_project_memory_into_profile` symlinks `~/.claude/projects/<cwd-slug>/memory` into the profile so the repo's Claude memory follows the isolated profile.
4. Reads the profile's `.claude.json` and **aborts** if it's authenticated as a different email than the managed account (pre-launch mismatch).
5. Invokes `claude --setting-sources user,project,local` (or `user,project` with `--exclude-local-settings`) under `CLAUDE_CONFIG_DIR=<profile>`, passing through anything after `--`.
6. Re-checks the profile email after exit. A post-run mismatch returns exit code **2** specifically — tests depend on this.

When editing `run`, remember: symlinks into `~/.claude` mean anything a global agent/hook/plugin does will still affect isolated profiles. That's intentional (documented in README's "Shared vs Isolated"), not a bug.

### `add` — strict re-auth flow

`command_add` requires `claude` on PATH and performs: snapshot current managed account → `claude auth logout` (forces re-auth, avoids silent browser-session reuse) → `claude auth login --claudeai` → verify the resulting email matches the requested email exactly → register. If authentication doesn't switch the active account, or lands on a different email, `add` fails without mutating the manifest. The failure messages are part of the test contract (`tests/test-add-command.sh`).

### `switch` — global auth rewrite

`command_switch` writes the target account's credentials into the active global credential store and merges the target's `oauthAccount` block into the live `~/.claude/.claude.json` (or `~/.claude.json` fallback, resolved by `get_claude_config_path`). It preserves everything else in the live config. After switching, the user must restart Claude Desktop / Claude Code.

### `update` — self-update

`command_update` downloads the latest published release bundle from GitHub, validates it with `bash -n`, compares the embedded `VERSION`, and replaces the current script (or `--prefix` target) in place. It reuses `run_maybe_sudo` for protected install dirs, so keep update/install behavior aligned.

### Interactive launcher (`src/50-launcher.sh`)

Running `claude-switch` with no args in a TTY triggers `command_launcher`, a framed switchboard UI. It accepts the same subcommands (plus slash-prefixed `/run`, `/help`, etc.) via `launcher_execute_line → run_subcommand`, which is the same dispatcher `main()` uses — so new subcommands wire through `src/50-launcher.sh:run_subcommand` and automatically become available in both modes. `CLAUDE_SWITCH_FORCE_INTERACTIVE=1` forces launcher mode from a non-TTY (used by `tests/test-interactive-shell.sh`).

### Entry point (`src/99-main.sh`)

`main()` pre-scans for `-y`/`--yes`, enforces the "no root outside a container" rule (bypassed for `help`/`version`/`install`/`uninstall`/`update`), rejects legacy `--flag` syntax with a migration hint, then dispatches via `run_subcommand`. `check_command_backend_requirements` is the single gate for per-command dependency checks.
