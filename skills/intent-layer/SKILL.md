---
name: intent-layer
description: Scaffold or audit a repo's hierarchical AGENTS.md Intent Layer. Use when initializing context infrastructure, adding AGENTS.md nodes to a complex subsystem, or auditing existing context files for size and coverage.
paths: ["**/AGENTS.md", "AGENTS.md"]
origin: arkira
---

# Intent Layer

Build and maintain a hierarchy of `AGENTS.md` context nodes so agents navigate the
repo like a senior engineer. The normative rules live in the Intent Layer section of
the repo's root `AGENTS.md`. Full rationale and examples:
`governance/intent-layer-standard.md`.

## Workflow

1. Detect state.
   `bash scripts/detect-state.sh <repo>` reports `none`, `partial`, or `complete` and
   lists existing context nodes.

2. Measure.
   `bash scripts/estimate-tokens.sh <repo>` ranks immediate subdirectories by token
   weight (chars / 4). `bash scripts/analyze-structure.sh <repo>` lists candidate
   subsystem directories with file counts.

3. Decide.
   `AGENTS.md` is the single shared root context. Add a child `AGENTS.md` only when a
   directory exceeds roughly 20k tokens, owns a distinct responsibility, or holds a
   cross-cutting concern (place that node at the lowest common ancestor). Do not add a
   node for every directory, a simple utility, or a test folder unless it is genuinely
   complex.

4. Execute.
   Each node opens with a READ-FIRST directive and stays under 4k tokens. `CLAUDE.md`
   and `CODEX.md` stay as role overlays at the root only; never place them below the
   root and never duplicate the normative content from `AGENTS.md`.
   In a repository with a tracked `.arkira/config.json`, the active host writes `AGENTS.md`
   directly by default. Optional delegation uses
   `ai-engineering/runtime/role-run.sh executor code_editing`. Direct work creates no Executor receipt.
   When an area produces or consumes a contract artifact (see
   `docs/document-contract.md`), record a short Document Contract line in its
   `AGENTS.md` node: what it reads, what it writes, and which skills sit upstream
   and downstream.

5. Maintain.
   When a subsystem grows or its responsibility shifts, re-run the measure step and
   split or update the nearest node. Document hidden contracts and invariants in the
   nearest ancestor node.

## Capture questions

When documenting existing code in a node, answer:

1. What does this area own, and what is out of scope?
2. What invariants must never be violated?
3. What repeatedly confuses a new engineer here?
4. What patterns must always be followed?
5. What documents does this area read and write, and which skills produce or consume them?
