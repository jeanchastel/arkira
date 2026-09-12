# Dependencies

External tools the plugin and its skills expect. SessionStart and sync checks never auto-install; they
reports gaps. Add a row when a new skill or hook introduces a tool.

| Tool | Used by | Required | Install |
|---|---|---|---|
| `bash` (4+) | all hooks, skill scripts | required | preinstalled on macOS/Linux; `brew install bash` for newer |
| coreutils (`find`, `wc`, `awk`, `sort`, `xargs`) | `intent-layer` skill scripts, hooks | required | preinstalled on macOS/Linux |
| `jq` | bootstrap scripts, `/arkira-sync` | required | `brew install jq` or `apt-get install jq` |
| `gh` | PR and release helpers | required for publishing | `brew install gh` or `apt-get install gh` |
| `git` | sync, version, CI helpers | required | preinstalled; `brew install git` |
| `node` | sentinel SHA tooling (`lint-canonical-sentinels.sh`, `sync-lib.sh`) | required for development | `brew install node` |
| `shellcheck` | local CI parity (`scripts/run-all-tests.sh`) | required for development | `brew install shellcheck` |
| `npx` (`markdownlint-cli2`) | markdown lint suite | optional (skipped if absent) | bundled with `node` |

Runtime CLI freshness for project tools (`vercel`, `supabase`, `gh`, `node`, `pnpm`,
`git`, `bun`, `wrangler`) is checked by the `cli_version_freshness` switch and
`hooks/cli-freshness-check.sh`; that check reports gaps and never installs.

## Suggested (optional) tools

Tools that pair well with the plugin but are not required and are never installed
or bundled. Some carry restrictive licenses (noncommercial, GPL), check each
before adopting on commercial or client repos. See
[`tooling/suggested-tools.md`](./tooling/suggested-tools.md): RTK (Rust Token
Killer), token-optimizer (PolyForm Noncommercial), Semble (MIT), and
codebase-memory-mcp (MIT).
