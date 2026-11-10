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

Gated by the `engineering_principles` switch (default on): Think Before Coding, Simplicity First, Surgical Changes, and Goal-Driven. The definitions live in that switch entry in `security/switches-reference.md`.

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

Follow `ai-engineering/workflows/feature-pass.md`. Use the repository's actual tooling, and do not claim validation passed unless it was executed.

## Model Optimization

See `governance/model-selection-standard.md` in the resolved Arkira plugin.

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

See `governance/role-contracts.md` for who publishes and `governance/candidate-gate-standard.md` for the helpers and their trust boundaries.

## Intent Layer

See `governance/intent-layer-standard.md` in the resolved Arkira plugin.

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
