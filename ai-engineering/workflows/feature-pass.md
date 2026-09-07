# Feature Pass Workflow

## Objective

Implement approved scope with the fewest model calls that still produce clean, production-ready
code. Tier selection follows [tier-routing.md](./tier-routing.md).

Use the callable `arkira:coding` skill from the resolved plugin for reuse, accessibility, and task discipline.

## Required Inputs

- Approved instructions. Include the spec and plan when the tier requires them.
- Preliminary tier and its trigger evidence.
- Current branch, working-tree state, protected files, and verification commands.

## Invariants

- The active host implements the approved scope directly by default and runs focused validation.
- A dispatched Executor owns only its delegated scope.
- An Executor never commits, pushes, publishes, deploys, or mutates remote services.
- Every behavior change is test-first: observe the focused test fail for the expected reason, make
  the smallest implementation, then observe focused green.
- User-facing work implements the approved journey and relevant responsive, accessibility, loading,
  empty, error, and interaction states.
- Customer-facing copy, including rendered UI, transactional email, and notifications, contains no em
  or en dashes. Documentation, plans, reports, and internal prose may use them.
- Visual polish never substitutes for correct behavior. Correct behavior never excuses an unfinished interface.
- Preserve existing user work and do not perform opportunistic cleanup.
- Bound every command with a hard timeout.
- One healthy run is enough. Never duplicate a progressing gate.
- During development, select one registered suite with
  `scripts/run-all-tests.sh --suite <id>`. Do not run its broader group.
- Direct work never fabricates an Executor receipt.
- When delegation adds judgment or isolation, use
  `ai-engineering/runtime/role-run.sh executor code_editing`. Do not use a provider-specific
  companion or resume a thread created outside the role runtime.
- Neither authoring mode grants Git, publication, deployment, or remote mutation authority.
- One integration owner delivers the accepted unit. Conversation or agent-subtask boundaries do not
  require a separate review, PR, merge, deployment, or operator continuation prompt.
- An active `/goal` is the bounded exception. Its durable goal state carries internal chunks without
  a routine conversation stop.

## Quick Path

Quick uses direct host implementation by default. When delegation adds value, use one Executor call:

```text
role-run.sh executor code_editing --prompt-file <combined-instructions>
```

Non-schema Executor dispatch is asynchronous by default, so the example needs no mode flag.

The delegated prompt contains the implementation scope and focused-validation requirement. The
Executor returns changed paths, tests added, exact validation commands, outcomes, and residual risk.
Permit a second dispatch only after a specific failed or incomplete result.
Record the reason. A retry is not part of the default path.

After the return, run post-diff tier routing. If scope or surface raises the tier, follow the higher
tier before certification and publication.

## Normal and Elevated Path

1. Read the approved spec and plan in full.
2. Confirm branch and worktree state without changing user-owned work.
3. Preflight dependencies and the focused test runner once.
4. Implement each plan step directly, or delegate a bounded Executor chunk when it adds value.
5. After each step, inspect changed paths and validation evidence. Retry only a concrete failure.
   Preserve a concise handoff at an interruption; continue authorized related work without a new
   conversation or approval merely because a subtask finished.
6. Run post-diff tier routing after the final implementation diff.
7. Hand the complete working tree to the candidate gate and Verifier workflow for the resulting tier.

## Verification Discipline

- Use directly related focused tests, lint, typecheck, or build checks during implementation.
- For Vitest, read the declared Vitest version and existing `package.json` scripts first. Prefer an
  existing script, and use that version's official documentation for flag spellings. Run the
  directly related file through the repository's declared package manager, for example
  `pnpm vitest run path/to/file.test.ts` in a pnpm repository. Never run bare `pnpm vitest run`,
  `npm test`, or the complete product test suite during ordinary implementation.
- Do not run full CI during ordinary implementation or final verification.
- Reserve full CI for an explicit operator request.
- Use focused evidence, the deterministic candidate minimum, and one code-quality review by default.
- For an explicitly requested full local candidate proof, stage the complete clean tree and run
  `candidate-gate.sh validate --repo . --full-ci` once. Certification reuses matching proof. A
  repeated full gate requires a documented invalidation reason.
- Required pull request CI is the one broad inventory run. Do not duplicate it locally unless the
  operator explicitly requests a full local proof.
- Prefer installed dependencies and offline-first package behavior. Disable retry storms.
- A blocked or timed-out check is a reported failure, not a reason to wait indefinitely.
- Never claim a pass without the terminal result from the exact candidate tested.

## Bootstrap Path

When a target repository predates the role runtime or candidate gate, prepare the corrective
canonical change in `arkira-labs-standards`. Verify focused bootstrap tests there.
Use the trusted `/arkira-sync` dry-run and apply transaction to install the dependency-closed runtime.
The target does not need its absent Executor to receive the tools.
Inspect the sync-only diff. Then resume this workflow for product changes.
Do not hand-edit the target or bypass approval-gated protections.

## Required Output

- Tier before and after the diff, with triggers.
- Files changed and tests added.
- Red and green commands with actual outcomes.
- Authoring modes, Executor call count, and any measured retry reason.
- Residual risk and the Verifier handoff.
- The completed semantic unit and sealed next action, unless an active `/goal` run owns
  the complete implementation-to-PR phase.
