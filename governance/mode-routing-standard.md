# Mode Routing Standard

This standard guides execution mode selection for a task. Select the mode from
the work's scope and keep single-pass execution as the default.

This standard governs the **execution mode** (how work is run). It is distinct
from `governance/model-selection-standard.md`, which governs the **model tier** (which
model runs it). The two are paired but separate.

## When to change modes

Use a non-default mode when the task warrants it:

- **Workflow / ultracode**: broad fan-out: comprehensive audits, whole-repo
  reviews, sweeps, `migrate all`, `find all bugs`. Parallel multi-agent work
  beats a single pass.
- **`/goal`**: a single end-to-end objective: `build X and ship it`,
  `end-to-end`, `autonomously`, `take this to done`. Runs plan → review → build
  → verify.

Agent swarms are routed by `prefer_agent_swarms`
(`governance/agent-swarm-standard.md`).
