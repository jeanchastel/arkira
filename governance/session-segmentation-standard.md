# Session Segmentation Standard

A conversation owns one semantic work unit. Durable repository artifacts and a
private sealed handoff carry work across conversations. Chat history is never the
only source of continuation state.

## Boundaries

- Design ends after the approved, reviewed plan.
- A feature plan names independently verifiable conversation chunks. One chunk
  normally contains one to three cohesive tasks.
- Remediation uses one coherent batch of compatible approved findings per conversation.
- Manual review starts in a fresh conversation or an isolated Verifier context.
- A 90-minute lease is a fallback. When due, finish the current atomic operation,
  seal the handoff, and rotate.
- `continue` requires an explicit reason and grants a 30-minute grace period. It
  does not authorize starting the next semantic unit.

`/goal` is the bounded exception. One active goal runs planning, implementation,
local acceptance, certification, and pull-request delivery without a routine
conversation pause. Internal Executor and Verifier calls remain isolated. The
goal runtime keeps durable recovery state at completed internal chunk boundaries.
An operator-approved remediation consolidation is a second bounded exception:
while one replacement pull request waits on hosted checks, the host may prepare
the next already-inventoried batch in a separate branch and worktree. Each batch
keeps its own scope, evidence, review, and publication boundary. Manual feature
and review work, and remediation outside such an approved consolidation, retains
the boundaries above.

## Runtime

Product repositories receive `scripts/session-handoff.sh` with these operations:

- `start --workflow <name> --unit <id> [--autonomous]`
- `status`
- `seal --reason <boundary|lease|operator> --input <markdown-file>`
- `resume [--workflow <name> --unit <id>] [--autonomous]`
- `continue --reason <text>`
- `close`

A sealed semantic input has exactly one non-empty section for Objective,
Completed, Decisions, Artifacts, Validation, Remaining, Next action, and Blockers
and risks. The runtime adds deterministic Git facts. Resume labels the handoff
fresh or stale by comparing branch, HEAD, and the worktree fingerprint. A stale
handoff is preserved and reconciled before mutation.

## Storage and safety

State lives under `~/.arkira/state/session-handoffs/<worktree-key>/`, outside Git.
Directories are `0700`; files are `0600`. Symlinks and unsafe file types fail
closed. Writes publish atomically. One active handoff and five completed handoffs
are retained per worktree.

The handoff may contain repository context but never secrets, credentials, raw
environment values, or copied tool payloads. Git metadata is labeled untrusted and
sanitized before display.

## Host integration

The shared workflow contract is authoritative. Claude Code uses a thin hook to
emit one line when a lease is due or a sealed handoff exists at session start.
Healthy and autonomous paths are silent. Other hosts follow the shared root
context and invoke the same synced runtime when the operator says
`Resume Arkira handoff`.
