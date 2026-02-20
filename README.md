# claude-switch

Multi-account switcher for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Manage and switch between multiple Claude Code accounts from the command line.

## Prerequisites

- **Bash 4.4+** — macOS ships 3.2; upgrade with `brew install bash`
- **jq** — `brew install jq` (macOS) or `apt install jq` (Linux)
- **Linux**: `libsecret-tools` — `sudo apt install libsecret-tools`
- **WSL**: PowerShell (built-in, needs `/mnt/c` access)
- Do not run as root — the script exits with an error if run as root outside a container environment

## Platform Support

| Platform | Credential Storage |
|----------|-------------------|
| macOS    | Keychain          |
| Linux    | libsecret keyring |
| WSL      | Windows DPAPI     |

Container environments (Docker, LXC, Kubernetes) are detected — the root-user restriction is relaxed inside containers, but the standard Linux (libsecret) backend is still used. If `secret-tool` is not installed the script will exit with an error. If `secret-tool` is installed but the container lacks a D-Bus session or keyring daemon, credential operations will silently fail. This tool is not recommended for headless/container use without a running keyring.

## Installation

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/botjaeger/claude-switch/main/claude-switch.sh \
  -o /tmp/claude-switch.sh && bash /tmp/claude-switch.sh --install && rm /tmp/claude-switch.sh
```

### From source

```bash
git clone https://github.com/botjaeger/claude-switch.git && cd claude-switch
./claude-switch.sh --install
```

### Custom path

```bash
./claude-switch.sh --install --prefix ~/.local/bin
```

### Uninstall

```bash
claude-switch --uninstall

# If installed to a custom prefix:
claude-switch --uninstall --prefix ~/.local/bin

# Skip the account-data removal prompt:
claude-switch --uninstall -y
```

### Manual install

```bash
git clone https://github.com/botjaeger/claude-switch.git && cd claude-switch
chmod +x claude-switch.sh
cp -p claude-switch.sh /usr/local/bin/claude-switch
```

After installation, all commands below can use `claude-switch` instead of `./claude-switch.sh`.

## Usage

### Add the currently logged-in account

```bash
claude-switch --add-account
```

Log into each Claude Code account and run this command to register it. Repeat for every account you want to manage. If the account is already managed, the command prints a message and exits without making changes. If no credentials are found (e.g. not logged in), the command exits with an error.

### List managed accounts

```bash
claude-switch --list
```

Output:

```text
Accounts:
  alice@example.com (active)
  bob@example.com
```

### Show current account

```bash
claude-switch --status
claude-switch --whoami
```

Output (managed account):

```text
Account: alice@example.com
Alias:   work
Usage:
  5-hour: ███░░░░░░░░░░░░░░░░░  15%  resets in 4h 16m
  7-day:  █░░░░░░░░░░░░░░░░░░░   8%  resets in 6d 2h
```

Output (not managed):

```text
Account: alice@example.com
(not managed)
Usage:
  5-hour: ░░░░░░░░░░░░░░░░░░░░   0%  resets in 3h 45m
  7-day:  ░░░░░░░░░░░░░░░░░░░░   2%  resets in 5d 11h
```

If no Claude Code session exists, prints `No active Claude account found.`

### Switch accounts

```bash
claude-switch --switch bob@example.com
claude-switch --switch work
```

Accepts an email address or alias. Resolution checks email first, then alias.

### Set an alias for an account

```bash
claude-switch --alias alice@example.com work
claude-switch --alias bob@example.com personal
```

The first argument can be an email or an existing alias. Aliases must be alphanumeric (hyphens and underscores allowed), cannot be purely numeric, and cannot look like an email address. An alias that is already assigned to another account is rejected with an error.

Once set, aliases can be used anywhere an email is accepted:

```bash
claude-switch --switch work
claude-switch --remove-account personal
```

Aliases appear in the account list:

```text
Accounts:
  alice@example.com [work] (active)
  bob@example.com [personal]
```

### Remove an alias

```bash
claude-switch --unalias work
```

Only accepts an alias name, not an email address.

### Remove an account

```bash
claude-switch --remove-account bob@example.com
claude-switch --remove-account personal
```

Prompts for confirmation (`[y/N]`, default no) before removing. Use `-y` / `--yes` to skip the prompt:

```bash
claude-switch --remove-account personal -y
```

The `-y` flag can appear anywhere in the argument list.

### Version

```bash
claude-switch --version
```

Output:

```text
claude-switch 1.0.0
```

### Help

```bash
claude-switch --help
```

Running with no arguments also shows the help message.

## How It Works

1. **Add** — Reads the active Claude Code session (config + credentials) and stores a backup in `~/.claude-switch-backup/`. The config is read from `~/.claude/.claude.json` (or `~/.claude.json` as a fallback).
2. **Switch** — Saves the current session, then restores the target account's config and credentials into the locations Claude Code reads from.
3. **Restart** — After switching, restart Claude Code to pick up the new authentication.

### Data stored

```text
~/.claude-switch-backup/
  sequence.json                            # account registry & active state
  configs/.claude-config-<N>-<email>.json  # hidden; use ls -a
  credentials/                             # macOS only
```

Credentials are stored securely per platform:
- **macOS**: Keychain entries under service names like `Claude Code-Account-<N>-<email>`
- **Linux**: libsecret keyring entries under service `claude-code` with `account` and `email` attributes per entry
- **WSL**: DPAPI-encrypted files at `%USERPROFILE%\.claude-switch\account-<N>-<email>.enc`

All files are created with `600`/`700` permissions.

## Typical Workflow

```bash
# 1. Log into your first Claude Code account, then register it
claude-switch --add-account

# 2. Sign into your second account in Claude Code, then register it
claude-switch --add-account

# 3. Give them aliases
claude-switch --alias alice@example.com work
claude-switch --alias bob@example.com personal

# 4. Switch between them anytime
claude-switch --switch work              # by alias
claude-switch --switch bob@example.com  # by email

# 5. Restart Claude Code after each switch
```

## Credits

Based on [cc-account-switcher](https://github.com/ming86/cc-account-switcher) by [@ming86](https://github.com/ming86) (MIT licensed), which itself was based on the [original gist](https://gist.github.com/botjaeger/943a13c8eec1d41339fbfe167cdc93ea) by [@botjaeger](https://github.com/botjaeger). Also inspired by [this gist](https://gist.github.com/Madd0g/dfad71d623784d6c1ec13d061a7b1de8) by [@Madd0g](https://github.com/Madd0g).

## License

[MIT](LICENSE)
