# Thread: claude-switch isolated profile launcher handoff

## Status: OPEN

## Goal

Carry forward the current `claude-switch` implementation work into a fresh thread without losing context.

## Context

Created from conversation on 2026-04-08.

Active repo:
- `/Users/jarngotostos/zzz/claude-switch`

What was implemented:
- Added isolated profile launching via `--run <email|alias> [-- ...]`.
- Added `--include-local-settings` for `--run`.
- Added deterministic profile directories under `~/.claude-switch-backup/profiles`.
- Added pre-launch and post-launch profile email validation.
- Marked `--switch` as legacy in help text, runtime messaging, and README.
- Added a shell integration test for the new launcher flow.
- Wired that integration test into Linux CI.

Key implementation details:
- `claude-switch.sh` now defines `PROFILES_DIR="$BACKUP_DIR/profiles"`.
- Profile paths are derived as `account-<num>-<email-slug>`.
- `--run` launches `claude` with:
  - `CLAUDE_CONFIG_DIR=<profile dir>`
  - `--setting-sources user,project` by default
  - `--setting-sources user,project,local` when `--include-local-settings` is used
- Passthrough Claude args are supported after the first `--`.
- If the isolated profile already belongs to another email, the wrapper exits before launch.
- If the launched Claude session authenticates as the wrong email, the wrapper exits with code `2`.

Files changed:
- `/Users/jarngotostos/zzz/claude-switch/claude-switch.sh`
- `/Users/jarngotostos/zzz/claude-switch/README.md`
- `/Users/jarngotostos/zzz/claude-switch/.github/workflows/ci.yml`
- `/Users/jarngotostos/zzz/claude-switch/tests/test-run-command.sh`

Local verification already run:
- `bash -n /Users/jarngotostos/zzz/claude-switch/claude-switch.sh`
- `bash /Users/jarngotostos/zzz/claude-switch/tests/test-run-command.sh /Users/jarngotostos/zzz/claude-switch/claude-switch.sh`

Current git state at handoff time:
- Branch: `main`
- Modified:
  - `.github/workflows/ci.yml`
  - `README.md`
  - `claude-switch.sh`
- Untracked:
  - `tests/`

Not done yet:
- No commit created.
- No branch created.
- No push performed.
- Full GitHub Actions matrix not run locally.

## References

- Main script: `/Users/jarngotostos/zzz/claude-switch/claude-switch.sh`
- Docs: `/Users/jarngotostos/zzz/claude-switch/README.md`
- CI workflow: `/Users/jarngotostos/zzz/claude-switch/.github/workflows/ci.yml`
- Integration test: `/Users/jarngotostos/zzz/claude-switch/tests/test-run-command.sh`

Relevant docs referenced during planning:
- `https://code.claude.com/docs/en/env-vars`
- `https://code.claude.com/docs/en/authentication`
- `https://code.claude.com/docs/en/settings`
- `https://github.com/anthropics/claude-code/issues/3833`

## Next Steps

- Review the changes in `claude-switch.sh` and confirm the `--run` UX is acceptable.
- Optionally run additional manual checks with a real Claude installation, for example:
  - `claude-switch --run work`
  - `claude-switch --run work -- --model sonnet`
  - `claude-switch --run work --include-local-settings -- --resume`
- If satisfied, create a branch, commit the changes, and push.
- If needed, add more CI coverage for macOS or WSL around `--run`.
