# Root Agent Standards

## Purpose

Define the baseline behavioral and operational rules for AI coding agents working in Arkira-governed repositories.

## Scope

Applies to:

- Claude Code
- Codex
- Cursor
- Gemini CLI
- future AI-assisted engineering workflows

## Core Rules

1. Read repository standards before modifying code.
2. Prefer minimal, reviewable changes.
3. Touch only files required for the task.
4. Verify behavior rather than assuming correctness.
5. Prioritize operational safety over elegance.
6. Prefer audit-first workflows.
7. Preserve working behavior unless a defect is proven.

## Engineering Principles

Gated by the `engineering_principles` switch (default on). Every change is held to four principles. They bind both Audit Mode and Implementation Mode and make the Core Rules above explicit.

1. **Think Before Coding.** Understand the system and form a plan before editing. Read the relevant standards, trace the affected paths, and know what done looks like before the first edit.
2. **Simplicity First.** Prefer the simplest design that works. No speculative abstraction, no framework for a one-off, no indirection that the task does not need. Complexity is added only when a concrete requirement forces it.
3. **Surgical Changes.** Touch only what the task requires. No opportunistic refactor, no drive-by reformatting, no unrelated cleanup. Keep the blast radius small and the diff reviewable.
4. **Goal-Driven.** Every change traces to the stated objective and is verified against it. If a change does not move the goal forward, it does not belong in the diff.

## Do Not

- Rewrite unrelated files.
- Perform opportunistic cleanup.
- Introduce broad refactors casually.
- Change architecture without explicit approval.
- Claim validation succeeded unless it was performed.
- Invent APIs, environment variables, or dependencies.
- Replace working systems for stylistic reasons alone.

## Audit Mode

### Purpose

Used for:

- architecture review
- security review
- AI slop detection
- operational risk analysis
- deployment review

### Rules

When auditing:

- do not modify files
- do not apply patches
- do not refactor
- do not install dependencies
- identify risks explicitly
- classify severity clearly
- distinguish cosmetic issues from operational risks

### Required Output

Audit findings should include:

- file path
- issue
- severity
- operational impact
- likely failure scenario
- remediation recommendation

## Implementation Mode

### Workflow

1. Identify the exact issue.
2. Identify affected files.
3. Inspect existing implementation.
4. Determine the smallest safe change.
5. Identify required validation.
6. Make the change.
7. Run validation.
8. Summarize results.

### Validation Required

Where applicable, run:

```bash
pnpm lint
pnpm typecheck
pnpm test
pnpm build
```

Use the repository's actual tooling.

Do not claim validation passed unless it was executed.

## Model Optimization

Follow `governance/model-selection-standard.md` in the resolved Arkira plugin. Choose models and delegation for verified quality and the complete task's elapsed time and tokens, including review and rework. Monetary cost is secondary unless the operator sets a budget.

## Severity Classes

- `P0 Critical`: external launch, disaster recovery, data integrity, or platform-control blocker.
- `P1 High`: fix before production reliance unless the risk is explicitly accepted.
- `P2 Medium`: real risk or maintainability debt that should follow P0/P1 work.
- `P3 Low`: hardening, hygiene, cosmetic, or speculative until verified.

## AI Slop Detection

### Watch For

- placeholder logic
- duplicate implementations
- hallucinated utilities
- dead files
- fake integrations
- mock systems in production
- over-abstraction
- weak error handling
- hardcoded temporary values
- fake loading states
- optimistic fallback assumptions

### Do Not

- scaffold abstractions without operational value
- leave TODO-driven unfinished systems
- create duplicate utilities
- generate fake completeness

## Branch Expectations

- Work on a dedicated branch for implementation work.
- Keep commits focused by coherent remediation batch or governance change.
- Do not commit secrets, local environment files, generated build output, or agent scratch files.

## Publishing And Acceptance Helpers

- `scripts/create-pr.sh` is considered a publishing helper.
- Publishing actions may be automated only after successful validation, a completed tier-proportionate review per `ai-engineering/workflows/review-pass.md`, a clean worktree, reviewed diff, and completed commit.
- `scripts/complete-candidate.sh` owns the normal commit, PR creation, and GitHub native auto-merge path for an exact certified candidate.
- `scripts/merge-current-pr.sh` is manual recovery only. Native auto-merge waits for required GitHub checks and resolved threads without a human merge action.
- The authoring role reports intended commit boundaries. It does not commit, push, create pull requests, or execute merge helpers.
- The host orchestrator owns publishing after exact-candidate review. A changed head, failed check, conflict, base drift, or missing permission leaves the PR open and is reported without an automatic retry.
- Publication certification and GitHub merge enforcement are separate operational trust boundaries.

## Intent Layer

Context files form a hierarchy of `AGENTS.md` nodes:

- `AGENTS.md` is the single shared, tool-agnostic root context every agent reads. `CLAUDE.md` and `CODEX.md` are role overlays that point at it and never duplicate its normative content. Build the hierarchy from child `AGENTS.md` files in subdirectories, never from extra `CLAUDE.md` or `CODEX.md` files below the root.
- Every node opens with a READ-FIRST directive and stays under 4k tokens.
- Add a child `AGENTS.md` when a directory exceeds roughly 20k tokens, when responsibility shifts to a new domain, or for a cross-cutting concern placed at the lowest common ancestor. Document hidden contracts and invariants in the nearest ancestor node.
- Do not create nodes for every directory, simple utilities, or test folders unless genuinely complex.

Rationale and examples: <https://github.com/jeanchastel/arkira-labs-standards/blob/main/governance/intent-layer-standard.md>

## Pull Request Discipline

Changes should:

- remain focused
- minimize blast radius
- include validation details
- identify deployment implications
- avoid unrelated cleanup

## Final Standard

Working software beats impressive scaffolding.

Verified behavior beats plausible explanations.

Small safe changes beat heroic rewrites.
