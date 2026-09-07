# Agent Swarm Standard

Status: canonical. Synced to product repositories via `/arkira-sync`.

## Decision

Parallelism is an implementation option, not ceremony. Use it when two or
three independent units reduce elapsed time or isolate large read results.
Otherwise use one agent. The cap is three units.

`prefer_agent_swarms` defaults on. The switch permits eligible runtime-backed
fan-out. It does not require fan-out and does not assert that a host-native
agent feature is deterministic.

## Read units

Read units may overlap in scope. They run in isolated contexts and return one
self-contained conclusion with direct evidence. Select model and effort for total time and tokens through verified integration. Deduplicate findings before handing relevant facts to a writer.

## Write units

Write units require an active goal, a schema-version-2 parent Task contract,
and a schema-version-1 swarm manifest. Two or three writers may run only when
their declared scopes are pairwise disjoint. Each starts in a separate
worktree from the same exact synthetic snapshot of the primary worktree,
including adopted dirty paths.

Each writer inherits the parent model and effort, may change only its unit
scope, and runs one exact focused check. A failed unit receives one fresh repair
attempt from the clean snapshot. A second failure is terminal. Successful peer
results remain private and are not applied after any terminal unit failure.

The supervisor records timing, model, effort, prompt, result, retry, output, and
error paths in private state. It integrates one combined binary patch only when
the primary branch, HEAD, and synthetic worktree tree still match the dispatch
fingerprint. It verifies the combined tree before and after apply.

An optional final serial unit may own shared paths or cross-cutting integration.
It runs after independent writers and before primary integration. It is never a
concurrent writer.

## Runtime

Use `bin/arkira swarm <repo> dispatch|status|watch|recover|terminate`. Do not
bypass this runtime for write fan-out. A sequential fallback must be reported
as sequential. Report a swarm only when durable runtime evidence exists.

## Off state

When `prefer_agent_swarms` is off, use one writer and inline reads unless the
operator explicitly requests parallel read-only work.

Each unit has a question, evidence requirements, owned output, and stopping condition.
The integration owner deduplicates findings and validates the combined delivery unit.
Do not recursively delegate or create separate PRs/deployments for related unit results.
