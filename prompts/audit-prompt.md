# Audit Prompt

## Purpose

Define the standardized read-only audit workflow for Arkira-governed repositories.

## Scope

Use for:

- architecture review
- security review
- AI slop detection
- production readiness analysis
- operational risk analysis
- deployment review
- code hygiene review

## Audit Rules

When auditing:

- do not modify files
- do not apply patches
- do not refactor
- do not install dependencies
- do not perform cleanup
- do not rewrite systems

Audit first.

Implementation comes later.

## Audit Workflow

1. Inspect repository structure.
2. Identify architecture patterns.
3. Identify operational risks.
4. Identify security risks.
5. Identify AI slop patterns.
6. Classify severity.
7. Produce remediation recommendations.
8. Avoid implementation.

## Severity Levels

Use the canonical P0 to P3 labels from the Severity Classes block in `ai-engineering/root/AGENTS.md`.

## Required Findings Format

Each finding should include:

- file path
- issue summary
- severity
- operational impact
- likely failure scenario
- remediation recommendation
- validation requirements

## AI Slop Detection

### Watch For

- fake completeness
- placeholder logic
- dead AI-generated files
- duplicate implementations
- fake integrations
- mock systems in production
- excessive abstraction
- hallucinated utilities
- optimistic fallback assumptions
- UI polish masking backend weakness

## Operational Risk Review

Evaluate:

- deployment safety
- rollback readiness
- environment handling
- secrets discipline
- runtime assumptions
- scaling limitations
- monitoring gaps
- operational observability

## Validation Language

Use explicit validation language:

- `Validation required:`
- `Validation performed:`
- `Validation not performed:`

Do not imply successful validation without evidence.

## Final Standard

The goal of the audit is:

- operational clarity
- remediation prioritization
- governance enforcement
- risk visibility

Not code cleanup.
