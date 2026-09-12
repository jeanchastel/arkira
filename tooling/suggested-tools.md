# Suggested Tools

Optional tools that pair well with this plugin. None are required, installed,
vendored, or synced, this is a pointer list only. Some carry restrictive
licenses; check each before adopting on commercial or
client repos.

## RTK (Rust Token Killer)

Token-optimizing CLI proxy that wraps common dev commands and strips noise from
their output on heavy dev operations. Operator's own tool. Resolve the active binary with
`command -v rtk`; do not hardcode an installation path.

Usage: Claude Code configures the global Bash hook as `rtk hook claude`, which auto-rewrites
commands (`git status` -> `rtk git status`). Codex and other agents without the hook call
`rtk <cmd>` manually for heavy operations. Analytics: `rtk gain`.
Full convention: [`governance/rtk-token-killer-standard.md`](../governance/rtk-token-killer-standard.md).

License: operator's own tool, no restriction. Install: see upstream.

## token-optimizer

Audits a Claude Code or Codex setup for context-window waste, implements fixes,
and measures savings.

Usage: run the `token-optimizer` skill in Claude Code; `python3 measure.py quick`
for a fast overhead scan.

**License: PolyForm Noncommercial 1.0.0**: noncommercial use only. Third-party
(Alex Greenshpun, `github.com/alexgreensh/token-optimizer`). Do NOT adopt on
commercial or client repos without a separate commercial grant, and do not
bundle or redistribute it. Operator-global, personal noncommercial use only;
not vendored by this plugin.

## Code context

Semble provides local semantic code search. codebase-memory-mcp provides local
call-chain, impact-analysis, and dead-code tools over MCP. Install both once per
machine:

```bash
brew install uv && uv tool install semble
curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh | bash -s -- --skip-config
codebase-memory-mcp config set auto_watch false
claude mcp add codebase-memory -s user -- codebase-memory-mcp
printf '.codebase-memory/\n' >> "$(git config --global core.excludesFile || echo ~/.config/git/ignore)"
```

Plus one block in `~/.codex/config.toml`:

```toml
[mcp_servers.codebase-memory]
command = "codebase-memory-mcp"
```

Semble license: MIT. codebase-memory-mcp license: MIT. Operator-global, fully
local, and not vendored by this plugin.
