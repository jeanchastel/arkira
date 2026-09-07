# Remediation Pass Workflow

## Objective

Apply the smallest coherent batch of compatible approved findings, then prove the batch without
broadening scope. Tier selection follows [tier-routing.md](./tier-routing.md).

The remediation batch is the semantic boundary. Choose the fewest coherent, reviewable batches that can share one validation and publication cycle.
Do not assign an arbitrary batch count or create one PR per agent subtask.
Keep ordinary documentation-only changes in a separate batch so they can use the lighter validation
lane. Agent instructions, workflow contracts, and other behavior-shaping Markdown are not ordinary
documentation.

Use the callable `arkira:coding` skill from the resolved plugin for reuse and task discipline.

## Process

1. Inventory the remaining related remediation pull requests and findings. Record source pull request
   numbers, direct evidence, acceptance criteria, affected code, and overlap with current `main`.
2. Group compatible, independently reviewable changes into the fewest coherent batches. Separate
   ordinary documentation-only work from executable or behavior-shaping changes.
3. Create an isolated branch and worktree from current `main` for the batch. Bring in the source pull
   request changes, resolving overlaps in favor of current `main`. Treat already-present or redundant
   work as superseded; do not restore duplicate helpers or retired patterns.
4. Confirm the preliminary tier from planned paths and approval-gated surfaces. Define the narrowest
   regression coverage for each meaningful behavior change.
5. The active host implements the approved scope directly by default. Work test-first and use
   the focused timeout.
   When delegation adds value, use `ai-engineering/runtime/role-run.sh executor code_editing` with
   the finding and exact scope. Never substitute a legacy provider companion.
6. Inspect the resulting diff and validation evidence. Reject unrelated refactors or cleanup.
   Direct work never fabricates an Executor receipt.
7. Reclassify from the actual diff. A higher post-diff tier controls certification and review.
8. Run focused checks and the deterministic candidate minimum. Certify the combined candidate once.
   Required PR CI owns broad integration validation. A full local inventory is explicit opt-in;
   certification reuses matching evidence without repeating it.
9. Hand the staged candidate to the Verifier. The host orchestrator retains Git, remote, and publish
   ownership.
10. Publish one replacement pull request with explicit source pull request references, arm guarded
    auto-merge, and only then close superseded source pull requests with a link to the replacement.
    Never delete source branches as part of supersession.
11. While hosted checks run, prepare the next approved batch in another isolated worktree. Do not
    pause for routine status polling. Surface only a product decision, approval-gated action, security
    concern, or unresolved behavioral conflict.
12. Seal the remediation handoff with the batch inventory, exact evidence, residual risk, replacement
    pull request, superseded sources, and next action.

## Constraints

- Preserve behavior outside the approved batch.
- Do not touch dependencies, migrations, auth, payments, infrastructure, CI, environment, or
  deployment without the approval required by the resulting tier.
- Never run destructive Git, database, or cloud commands.
- Neither authoring mode grants Git, publication, deployment, or remote mutation authority.
- One measured retry is allowed only for a specific failed or incomplete Executor result.
- A batch must remain independently reviewable. Do not combine changes merely because they are in the
  same backlog.

## Required Output

- Findings and source pull requests addressed, including work superseded by current `main`, and final
  tier.
- Files changed and focused test evidence.
- Any skipped validation and why.
- Residual risk, Verifier handoff, replacement pull request, and supersession results.
