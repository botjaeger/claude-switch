# claude-switch

[![CI](https://github.com/botjaeger/claude-switch/actions/workflows/ci.yml/badge.svg)](https://github.com/botjaeger/claude-switch/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/botjaeger/claude-switch)](https://github.com/botjaeger/claude-switch/releases/latest)
[![License](https://img.shields.io/github/license/botjaeger/claude-switch)](LICENSE)

> The multi-account switcher for Claude Code and Claude Desktop.

Stop logging out. Stop guessing which account is active. Keep `work`, `personal`, and client accounts one command away.

`claude-switch` is a cross-platform Bash CLI and Claude account switcher for developers who regularly move between Claude accounts. Launch isolated Claude Code CLI sessions per account or switch the global account used by Claude Desktop from one command-line tool.

If you are looking for a Claude Code account switcher, a Claude Desktop account switcher, or a way to manage multiple Claude accounts on one machine, this is what the project is built for.

It can:

- launch isolated terminal `claude` sessions per account
- switch the global Claude auth/config used by Claude Desktop and default-profile workflows
- manage aliases, account snapshots, and secure per-account credentials from one CLI

Version 2 introduces a new v2 state store, a launcher-first terminal experience, modular source under `src/`, and an explicit `import-legacy` path from the old `~/.claude-switch-backup` layout.

## Why use it?

If any of these are familiar, `claude-switch` is for you:

- you use separate work and personal Claude accounts
- you jump between multiple client or tenant accounts
- you want Claude Desktop on one account and CLI sessions on another
- you are tired of manual sign-out and sign-in loops just to change context

## What you get

| Need | `claude-switch` behavior |
|------|---------------------------|
| Keep multiple accounts ready | Stores managed accounts with aliases like `work` or `personal` |
| Open a CLI session as a different account | `run <email-or-alias>` launches `claude` in an isolated per-account profile |
| Change the global account for Claude Desktop | `switch <email-or-alias>` rewrites the active global Claude auth/config |
| Keep your tooling | Shared user surfaces like settings, agents, hooks, plugins, and skills still load in `run` profiles |
| Avoid plaintext credential sprawl | Uses Keychain on macOS, `libsecret` on Linux, and DPAPI on WSL |

## Install

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/botjaeger/claude-switch/main/claude-switch.sh \
  -o /tmp/claude-switch.sh && bash /tmp/claude-switch.sh install && rm /tmp/claude-switch.sh
```

### From source

```bash
git clone https://github.com/botjaeger/claude-switch.git
cd claude-switch
./claude-switch.sh install
```

### Custom prefix

```bash
./claude-switch.sh install --prefix ~/.local/bin
```

### Update or uninstall

```bash
claude-switch update
claude-switch update --prefix ~/.local/bin

claude-switch uninstall
claude-switch uninstall --prefix ~/.local/bin
claude-switch uninstall -y
```

## Quick start

```bash
# Add a managed account and give it a short alias
claude-switch add alice@example.com work

# Add another account
claude-switch add bob@example.com personal

# See what is managed
claude-switch list

# Open an isolated Claude CLI session as "work"
claude-switch run work

# Or change the global account used by Claude Desktop
claude-switch switch personal

# Open the interactive launcher
claude-switch
```

## The mental model

### `run` for isolated CLI sessions

Use `run` when you want the current terminal session to act as a different Claude account without changing the global account used by Claude Desktop.

```bash
claude-switch run work
claude-switch run work -- --model sonnet
claude-switch run work -- --resume
claude-switch run work --exclude-local-settings -- --resume
```

What `run` does:

- points `CLAUDE_CONFIG_DIR` at an isolated per-account profile under `~/.claude-switch/profiles/...`
- keeps auth isolated per account
- keeps your normal user tooling available by linking shared Claude surfaces into the profile
- validates the profile email before launch and after exit
- supports passthrough Claude args after `--`
- uses `--setting-sources user,project,local` by default
- supports `--exclude-local-settings` when you want `user,project` only
- still accepts `--include-local-settings` for compatibility, even though local settings are already included by default

### `switch` for global Desktop/default-profile changes

Use `switch` when you want to change the global Claude auth/config used by Claude Desktop and other default-profile workflows.

```bash
claude-switch switch work
claude-switch switch personal
```

After switching, restart Claude Desktop or Claude Code.

## Interactive launcher

Run `claude-switch` with no arguments in a TTY to open the interactive launcher.

```bash
claude-switch
```

The launcher presents a switchboard-style terminal UI with a session summary, managed accounts, command hints, and a minimal prompt. Example inputs:

- `add alice@example.com work`
- `run work`
- `switch personal`
- `list`
- `status`
- `import-legacy`
- `help`
- `quit`

Slash-prefixed variants such as `/help` and `/run work` are also accepted.

## Command guide

### `add`

`add <email> [alias]` runs `claude auth login --claudeai`, lets Claude Code complete its own authentication flow, then captures the newly active global Claude account into `claude-switch`.

```bash
claude-switch add alice@example.com work
claude-switch add bob@example.com personal
```

Important behavior:

- the email is required
- the optional second argument is an alias
- the current managed global account is snapshotted before the new auth flow begins
- Claude Code is logged out first so an existing browser session cannot silently skip reauthorization
- if the browser shows an Authentication Code, copy it and paste it back into the waiting terminal
- the authenticated email must match the email you requested
- if Claude authenticates as a different account, `add` fails instead of guessing

### `status` and `whoami`

These commands show the current global account and alias when the active account is managed. Usage output is best-effort and silently skipped when no usable token is available.

```bash
claude-switch status
claude-switch whoami
```

### `update`

`update` downloads the latest published `claude-switch.sh` release bundle from GitHub and replaces the currently running installed script.

```bash
claude-switch update
claude-switch update --prefix ~/.local/bin
```

### Aliases

Aliases are designed for day-to-day switching:

- must be alphanumeric, hyphens, or underscores
- cannot be purely numeric
- cannot look like an email address

Email resolution always wins before alias resolution.

```bash
claude-switch alias alice@example.com work
claude-switch unalias work
claude-switch remove personal
```

Identifier usage:

- `add` requires a real email, with an optional alias
- `run`, `switch`, `remove`, and `alias` accept either an alias or an email

### Full command list

```bash
claude-switch add alice@example.com work
claude-switch list
claude-switch run work -- --model sonnet
claude-switch run work --exclude-local-settings -- --resume
claude-switch switch personal
claude-switch status
claude-switch whoami
claude-switch alias alice@example.com work
claude-switch unalias work
claude-switch remove personal
claude-switch import-legacy
claude-switch update
claude-switch help
claude-switch version
```

## Shared vs isolated

When you use `claude-switch run`, the isolated profile is not a full clean-room Claude home.

Shared into the isolated profile:

- user settings from `~/.claude/settings.json`
- user-scoped agents from `~/.claude/agents`
- user-scoped commands, hooks, skills, plugins, and agent memory from `~/.claude`
- the current repo's Claude project memory from `~/.claude/projects/<project>/memory`
- normal Claude setting resolution for `user,project,local` unless you pass `--exclude-local-settings`

Isolated per account/profile:

- Claude authentication
- the profile's `.claude.json`
- per-profile runtime and session state under `~/.claude-switch/profiles/...`
- project and session data outside the linked `memory/` folder

In practice, `run` isolates account identity while preserving your normal Claude developer environment.

## Security model

> `claude-switch run` is built for multi-account convenience, not hard isolation.

- account auth is isolated per profile
- shared user tooling is still shared across profiles: agents, hooks, plugins, skills, commands, and user memory can all affect every `run` profile
- current-project Claude memory is also shared into the isolated profile for the repo you launch from
- `switch` has a larger blast radius than `run` because it changes the global Claude auth/config
- if you need hard separation, use separate OS users, separate machines, or a fully separate Claude home

## Platform support

| Platform | Global credential backend | Stored account backend |
|----------|----------------------------|------------------------|
| macOS    | Keychain                   | Keychain               |
| Linux    | `libsecret`                | `libsecret`            |
| WSL      | Windows DPAPI              | Windows DPAPI          |

## Prerequisites

- Bash 4.4+
- `jq`
- Linux: `libsecret-tools`
- WSL: `powershell.exe` and `wslpath`

Do not run `claude-switch` as root outside a container.

## Legacy migration

Version 2 uses a new state directory:

```text
~/.claude-switch/
```

If legacy data exists at:

```text
~/.claude-switch-backup/
```

then:

- interactive launcher mode prompts to import it
- non-interactive commands ask you to run `claude-switch import-legacy`

`import-legacy` performs a one-time migration of:

- account registry data from `sequence.json`
- config snapshots from the legacy `configs/` directory
- isolated profile directories from the legacy `profiles/` directory
- stored per-account credentials from the legacy backend naming scheme

After import, v2 reads and writes only the new layout.

## Storage layout

```text
~/.claude-switch/
  manifest.json
  configs/
    <account-id>.json
  profiles/
    <account-id>-<email-slug>/
```

The manifest is versioned and uses stable account IDs instead of legacy numeric IDs.

## Development

Version 2 is developed from modular Bash source under `src/` and bundled into the user-facing release script.

```bash
./scripts/build.sh
bash -n claude-switch.sh
```

Useful test commands:

```bash
bash tests/test-run-command.sh ./claude-switch.sh
bash tests/test-add-command.sh ./claude-switch.sh
bash tests/test-interactive-shell.sh ./claude-switch.sh
bash tests/test-import-legacy.sh ./claude-switch.sh
bash tests/test-alias-lifecycle.sh ./claude-switch.sh
bash tests/test-install-uninstall.sh ./claude-switch.sh
bash tests/test-update-command.sh ./claude-switch.sh
```

The generated release artifact remains:

```text
claude-switch.sh
```

## License

[MIT](LICENSE)
