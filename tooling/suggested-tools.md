# Suggested Tools

Optional tools that pair well with this plugin. None are required, installed,
vendored, or synced, this is a pointer list only. Some carry restrictive
licenses (noncommercial, GPL); check each before adopting on commercial or
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

## igraph + Leiden

Graph analysis (`igraph`) plus the Leiden community-detection algorithm
(`leidenalg`). Pairs with code knowledge-graph and code-review-graph workflows:
clustering a dependency or call graph into communities, finding hub and bridge
nodes, mapping subsystem structure.

Install: `pip install igraph leidenalg` (or `conda install -c conda-forge
python-igraph leidenalg`).

**License: GPL** (`igraph` GPL-2.0, `leidenalg` GPL-3.0). External analysis use
only. Run them as standalone tools; do not bundle or link them into this
MIT-licensed plugin or any distributed product code. Operator-global, not
vendored by this plugin.
