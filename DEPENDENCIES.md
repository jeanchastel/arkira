# Dependencies

External tools the plugin and its skills expect. SessionStart and migration preview never auto-install; they
report gaps. Add a row when a new skill or hook introduces a tool.

| Tool | Used by | Required | Install |
|---|---|---|---|
| `bash` (4+) | all hooks, skill scripts | required | preinstalled on macOS/Linux; `brew install bash` for newer |
| coreutils (`find`, `wc`, `awk`, `sort`, `xargs`) | `intent-layer` skill scripts, hooks | required | preinstalled on macOS/Linux |
| `jq` | bootstrap scripts, canonical inventory check | required | `brew install jq` or `apt-get install jq` |
| `gh` | PR and release helpers | required for publishing | `brew install gh` or `apt-get install gh` |
| `git` | migration, version, CI helpers | required | preinstalled; `brew install git` |
| `node` | migration inventory and runtime helpers | required for development | `brew install node` |
| `shellcheck` | local CI parity (`scripts/run-all-tests.sh`) | required for development | `brew install shellcheck` |
| `npx` (`markdownlint-cli2`) | markdown lint suite | optional (skipped if absent) | bundled with `node` |

Runtime CLI freshness for project tools (`vercel`, `supabase`, `gh`, `node`, `pnpm`,
`git`, `bun`, `wrangler`) is checked by the `cli_version_freshness` switch and
`ai-engineering/scripts/cli-freshness-check.sh`; its `--report` path reports gaps
and never installs, while `--apply` runs installer commands for currently
installed tracked tools.

## Suggested (optional) tools

Tools that pair well with the plugin but are not required and are never installed
or bundled. Some carry restrictive licenses (noncommercial, GPL), check each
before adopting on commercial or client repos. See
[`tooling/suggested-tools.md`](./tooling/suggested-tools.md): RTK (Rust Token
Killer), token-optimizer (PolyForm Noncommercial), Semble (MIT), and
codebase-memory-mcp (MIT).
