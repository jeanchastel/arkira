# RTK (Rust Token Killer) Standard

Status: reference. Not synced to product repos. Operator-global tooling.

RTK is an installed CLI plus a global Claude Code hook. This plugin does not
vendor, bundle, or sync it. This doc records the convention so in-repo agents
know to prefer `rtk` and how to verify it.

The CLI freshness helper reports a Homebrew-managed RTK installation and includes
it in explicit `--apply` runs. Tracking does not make RTK a repository dependency
or install it when absent.

## Weekly automation

Run the explicit updater every Monday at 04:00 local time. Replace the two
absolute example paths with the resolved standards checkout and operator home
paths before installing the line with `crontab -e`.

```text
0 4 * * 1 PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin /absolute/path/to/arkira-labs-standards/hooks/cli-freshness-check.sh --apply >> /absolute/path/to/operator-home/.arkira/cli-freshness-cron.log 2>&1
```

The hook refuses to apply updates while an Executor job is active. The log is
operator-local state and must remain outside the repository.

## What

RTK = Rust Token Killer. A token-optimizing CLI proxy that wraps common dev commands and strips
noise from their output. Resolve it with `command -v rtk`; installation paths are not stable.

## Rule

Prefer `rtk` for token-heavy dev commands.

- **Claude Code:** the global Bash hook command is exactly `rtk hook claude`, so the active PATH
  resolves the binary. It auto-rewrites commands such as `git status` to `rtk git status`.
- **Codex and other agents without the hook:** call `rtk <cmd>` manually for
  heavy operations (git, build, test, grep, listing large trees).

## Meta commands (call `rtk` directly)

| Command | Purpose |
|---|---|
| `rtk gain` | Token savings analytics |
| `rtk gain --history` | Command usage history with savings |
| `rtk discover` | Analyze Claude Code history for missed opportunities |
| `rtk proxy <cmd>` | Run a raw command without filtering (debugging) |

## Health verification

Run `ai-engineering/runtime/role-manage.sh doctor`. When RTK is absent, doctor reports it as optional
and unavailable and does not fail the command. It fails when the PATH binary is not Rust Token
Killer, the configured Claude Bash hook hardcodes a stale path, or a live hook probe does not
rewrite the command. `status` reports the resolved path, version, hook health, and measured savings
when `rtk gain` can read the existing ledger.

Never move, delete, recreate, or reset the RTK savings database as a health repair.

## Name collision

If `rtk gain` fails, first verify `rtk --version` and the live hook probe. A ledger read failure is
separate from binary identity and must not trigger database deletion. Another binary named `rtk`
may be reachingforthejack/rtk rather than Rust Token Killer.

## Scope

Operator-global only. There is no per-repo install and no `/arkira-sync`
target. Product repos inherit the behavior through the operator's global
Claude Code hook, not through this plugin.
