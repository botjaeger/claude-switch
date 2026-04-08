# claude-switch

`claude-switch` is a cross-platform multi-account switcher for Claude. It can:

- launch isolated terminal `claude` sessions per account
- switch the global Claude auth/config used by Claude Desktop and default-profile workflows
- manage aliases, account snapshots, and account credentials from one CLI

Version 2 rewrites the project around a new v2 state store, a launcher-first terminal experience, and an explicit `import-legacy` path from the old `~/.claude-switch-backup` layout.

## Prerequisites

- Bash 4.4+
- `jq`
- Linux: `libsecret-tools`
- WSL: `powershell.exe` and `wslpath`

Do not run `claude-switch` as root outside a container.

## Platform Support

| Platform | Global Credential Backend | Stored Account Backend |
|----------|---------------------------|------------------------|
| macOS    | Keychain                  | Keychain               |
| Linux    | libsecret                 | libsecret              |
| WSL      | Windows DPAPI             | Windows DPAPI          |

## Installation

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

### Uninstall

```bash
claude-switch uninstall
claude-switch uninstall --prefix ~/.local/bin
claude-switch uninstall -y
```

## Quick Start

```bash
# 1. Add a managed account by email and set an alias
claude-switch add alice@example.com work

# 2. Add another account
claude-switch add bob@example.com personal

# 3. Open the interactive launcher
claude-switch

# 4. Or use direct commands
claude-switch run work
claude-switch switch personal
```

## Usage

### Interactive launcher

```bash
claude-switch
```

With no arguments in a TTY, `claude-switch` opens a switchboard-style launcher with a session summary, managed profiles, command hints, a muted status line, and a minimal `›` prompt. Type commands such as:

- `add alice@example.com work`
- `run work`
- `switch personal`
- `list`
- `status`
- `import-legacy`
- `help`
- `quit`

Slash-prefixed variants like `/help` and `/run work` are also accepted in the launcher.

### Commands

```bash
claude-switch add alice@example.com work
claude-switch list
claude-switch run work -- --model sonnet
claude-switch run work -- --resume
claude-switch run work --exclude-local-settings -- --resume
claude-switch switch personal
claude-switch status
claude-switch whoami
claude-switch alias alice@example.com work
claude-switch unalias work
claude-switch remove personal
claude-switch import-legacy
claude-switch help
claude-switch version
```

### `add`

`add <email> [alias]` runs `claude auth login --claudeai`, lets Claude Code complete its own authentication flow, then captures the newly active global Claude account into `claude-switch`.

- The email is required, for example `claude-switch add alice@example.com work`.
- The optional second argument is an alias.
- It snapshots the current managed global account before starting the new auth flow.
- It logs Claude Code out first so an already-authenticated web session cannot silently skip reauthorization.
- If Claude opens a browser page that shows an Authentication Code, copy that code and paste it back into the waiting terminal.
- After Claude Code finishes authentication, the authenticated email must match the email you requested.
- If Claude authenticates as a different account, `add` fails instead of guessing what you meant.

### `run`

`run` launches the `claude` CLI with `CLAUDE_CONFIG_DIR` pointed at a per-account profile directory under the v2 state root.

- It does not change the global Claude config used by Claude Desktop.
- It keeps auth isolated, but links shared user-scoped Claude surfaces like `~/.claude/settings.json`, `~/.claude/agents`, and `~/.claude/plugins` into the isolated profile so your user tooling still loads.
- It also links the current project's Claude memory store from `~/.claude/projects/<project>/memory` when that memory exists, so repo-specific memory still follows the isolated profile.
- It supports passthrough Claude args after `--`.
- It validates the profile email before launch and after exit.
- By default it uses `--setting-sources user,project,local`.
- Add `--exclude-local-settings` to use `user,project` when you want a cleaner isolated profile.
- `--include-local-settings` is still accepted for compatibility, but it is now the default behavior.

### `switch`

`switch` updates the global Claude auth/config used by Claude Desktop and other default-profile workflows. After switching, restart Claude Desktop or Claude Code.

## Shared vs Isolated

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
- per-profile runtime/session state created under `~/.claude-switch/profiles/...`
- project/session data outside the linked `memory/` folder

In practice, `run` isolates account identity while preserving your normal Claude developer environment.

## Security

`claude-switch run` is designed for multi-account convenience, not strict environment isolation.

- Account auth is isolated per profile.
- Your shared user tooling is still shared: agents, hooks, plugins, skills, commands, and user memory can all affect every `run` profile.
- Current-project Claude memory is also shared into the isolated profile for the repo you launch from.
- If you need hard separation between accounts, do not rely on `claude-switch` alone. Use separate OS users, separate machines, or a fully separate Claude home.
- `switch` changes the global Claude auth/config, so it has a larger blast radius than `run`.

### `status`

`status` and `whoami` show the current global account and alias when the active account is managed. Usage output is best-effort and silently skipped when no usable token is available.

### Aliases

Aliases:

- must be alphanumeric, hyphens, or underscores
- cannot be purely numeric
- cannot look like an email address

Email resolution always wins before alias resolution.

Identifier usage:

- `add` requires a real email, with an optional alias: `claude-switch add alice@example.com work`
- `run`, `switch`, `remove`, and `alias` accept either an alias or an email
- use aliases for day-to-day commands once an account has one
- use the email when the account has no alias yet, or when assigning/changing the alias

## Legacy Migration

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

## Storage Layout

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

The generated release artifact is still:

```text
claude-switch.sh
```

## Credits

Originally derived from [cc-account-switcher](https://github.com/ming86/cc-account-switcher) by [@ming86](https://github.com/ming86) (MIT licensed), which was itself based on your [original gist](https://gist.github.com/botjaeger/943a13c8eec1d41339fbfe167cdc93ea) as [@botjaeger](https://github.com/botjaeger). Also inspired by [this gist](https://gist.github.com/Madd0g/dfad71d623784d6c1ec13d061a7b1de8) by [@Madd0g](https://github.com/Madd0g).

## License

[MIT](LICENSE)
