# Knowledge Graph Standard

Gated by the repo-local `knowledge_graph` switch (seeded on by default). The
SessionStart hook stays silent and state-free unless that explicit repo config
exists and the switch is `true`. When on, Arkira-governed repos keep a per-repo
code knowledge graph provisioned and current with zero
manual upkeep, so impact analysis, hub/bridge detection, and semantic code
search are available the moment a review starts.

## What it does

- **Provision at init/sync.** `/arkira-init` and `/arkira-sync` build the graph
  for the repo if it is missing, so a freshly adopted or freshly synced repo has
  a graph from the first session.
- **Self-heal.** A SessionStart hook (`hooks/graph-maintain.sh`) health-checks
  the graph; a missing, empty, or corrupt graph triggers a full rebuild.
- **Self-update.** A healthy graph gets an incremental update instead. The hook
  is throttled to at most once per 24h per repo, runs the build/update in the
  background, and never blocks the session.

## The external builder is never bundled

The graph is built by the `code-review-graph` CLI, an operator-installed,
operator-global tool. Its engine (`igraph` + Leiden community detection) is
**GPL** and is **never bundled or linked** into this MIT-licensed plugin or any
product code (see `tooling/suggested-tools.md`). The plugin only shells out to
the CLI when it is present on `PATH`, exactly as the CLI-freshness hook shells
out to `vercel`/`supabase`. When the CLI is absent, every graph action is a
silent no-op, the switch can stay on safely in repos where the tool is not
installed.

## Boundaries

- The graph database (`.code-review-graph/graph.db`) is a per-machine cache that
  carries absolute paths; it is gitignored and never committed or shared.
- The hook touches only `.code-review-graph/` (the graph dir and its
  `.arkira-maintain` throttle stamp) and an append-only log at
  `~/.arkira/graph-maintain.log`. It never edits tracked files.
- This is repo-local maintenance, not an operator-global daemon. Operators who
  want continuous live updates can run `code-review-graph watch`/`daemon`
  themselves; that is out of scope for the plugin.

## Switch

`knowledge_graph` (tooling, seeded on). Set to `false` to disable provisioning
and maintenance. Configure via `/arkira-init`. The hook reads it from
`.arkira/config.json` at runtime (repo config first, then `~/.arkira/config.json`).
