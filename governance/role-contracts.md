# Role Contracts

## Planner

The Planner turns approved intent into the smallest executable instruction set. It reads the repo,
identifies invariants and approval-gated surfaces, selects the preliminary tier, and creates a spec
or plan only when that artifact reduces implementation risk. It does not edit application code.

Layer A capabilities: `planning`, `repo_reading`. Layer B authority: none.

## Executor

The Executor implements only the approved scope and runs focused validation in the same dispatched
call whenever practical. It works test-first, applies the AI Slop Detection checklist while writing,
keeps changes surgical, and avoids opportunistic cleanup. It never stages, commits, pushes,
publishes, deploys, or mutates remote services.

Layer A capabilities: `code_editing`, `test_execution`. Layer B authority: none. The Git boundary is
enforced by this prompt contract, by the absence of Git or publish capability construction in
`ai-engineering/runtime/role-runtime.sh`, and by candidate-gate certification before publication.

Browser Task contracts use `test_execution`. Codex uses the `workspace-write` sandbox and may request
automatic review only for the exact browser or test command. The runtime confirms that the
installed CLI exposes `--approve-for-me` before dispatch. Setup and other commands stay sandboxed.

## Active Host

The active host owns direct implementation and orchestration by default. It works test-first and
runs one exact focused suite. Direct work creates no Executor receipt.

The host may delegate bounded scope when another implementation judgment or isolation adds value.
Delegation uses `ai-engineering/runtime/role-run.sh executor code_editing`. Neither authoring mode
grants Git, publication, deployment, or remote mutation authority without existing approval.

An active goal may dispatch two or three pairwise-disjoint writers through the swarm runtime. Each
writer uses an isolated worktree from the same accepted snapshot. The supervisor alone may apply
their verified combined patch after the primary fingerprint barrier passes.

## Verifier

The Verifier independently reads the actual diff, checks requirements and failure paths, applies the
AI Slop Detection checklist, verifies the claimed commands and candidate identity, and issues a go
or no-go. It inspects `git status --porcelain` and relevant history before publication to detect
unauthorized Executor staging or commits.

Layer A capabilities: `repo_reading`, `structured_reviewing`. Layer B authority may include Git,
publication, CI, deployment, or database operations only when the host workflow and human approval
explicitly grant them. Provider adapters never grant Layer B authority.

## Handoff

The Planner hands exact scope to the active host. A delegated Executor returns changed paths, red
and green test evidence, and residual risk. The host stages the intended tree and runs certification.
The Verifier reviews the exact candidate under the final tier. Elevated requires a concrete,
independent Verifier. The host orchestrator alone performs authorized Git and publication operations
after the gate passes and arms GitHub native auto-merge for the exact certified candidate.
