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

This maintainer-edited section is mirrored into `ai-engineering/root/AGENTS.md` so subject repos
receive it. Reapply the mirror whenever this source section changes.

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
