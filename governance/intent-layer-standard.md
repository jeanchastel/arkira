# Intent Layer Standard

Plugin-local reference for the Intent Layer standard. The synced, normative rule lives
in the Intent Layer section of `ai-engineering/root/AGENTS.md`. This file carries the
rationale, the capture protocol, and worked examples. It is not synced into product
repos.

## Why

A single oversized root context file wastes tokens on every turn and buries the rules
that matter for the area an agent is actually working in. A hierarchy of small
`AGENTS.md` nodes keeps each context local, cheap, and READ-FIRST.

## The Arkira root-context model

Arkira uses one universal root authority and generates thin provider entrypoints only where an
adapter requires one.

- `AGENTS.md` is the single shared, tool-agnostic root context. Source of truth.
- Adapter `context_file` values other than `AGENTS.md` receive pointer-only overlays generated from
  adapter metadata. They contain no duplicated normative content.
- The hierarchy is built from child `AGENTS.md` nodes, never from extra `CLAUDE.md` or
  `CODEX.md` files below the root.

## When to create a child node

| Signal | Action |
|---|---|
| Directory exceeds ~20k tokens | Create a child `AGENTS.md`. |
| Responsibility shifts to a new domain | Create a child `AGENTS.md`. |
| Hidden contract or invariant | Document in the nearest ancestor node. |
| Cross-cutting concern | Place one node at the lowest common ancestor. |

Do not create nodes for every directory, simple utilities, or test folders unless
genuinely complex.

## Capture protocol

For each documented area answer: what it owns and excludes; the invariants that must
never break; what repeatedly confuses new engineers; the patterns to always follow; and, when the area participates in the document contract (`docs/document-contract.md`), what it reads and writes and which skills sit upstream and downstream.

## Tooling

The `intent-layer` skill ships `detect-state.sh`, `analyze-structure.sh`, and
`estimate-tokens.sh` to detect state, find boundaries, and rank directory weight.
