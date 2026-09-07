# CI Validation Standard

## Purpose

Define minimum automated validation expectations for Arkira-governed repositories.

## Scope

Applies to:

- production repositories
- SaaS applications
- Vercel applications
- AI-assisted software projects
- repositories with pull request workflows

## Core Doctrine

CI means automatic validation before merge or deployment.

CI should reduce obvious breakage without creating unnecessary complexity.

## Minimum Required Checks

Production-oriented repositories should run:

```bash
pnpm lint
pnpm typecheck
pnpm build
```

Where tests exist, also run:

```bash
pnpm test
```

Use repository-specific tooling where appropriate.

## Required Behavior

CI should verify:

- code style passes
- type safety passes
- production build succeeds
- tests pass where available
- generated code does not break the repository

## Do Not

- require complex pipelines before the repo is ready
- block progress with low-value checks
- add fake tests for appearance
- claim validation passed unless checks actually ran
- ignore failing production builds

## Pull Request Rules

Before merge, PRs should document:

- validation required
- validation performed
- validation not performed
- known risks
- deployment impact

## Vercel Relationship

Vercel preview builds are part of the validation system.

However:

- Vercel build success does not replace all security review
- Vercel preview success does not prove production environment correctness
- production deployment should still require review discipline

## AI-Assisted Development Rules

AI-generated changes should be validated with CI before merge.

AI agents must not treat plausible code as working code.

## Recommended Initial GitHub Actions Scope

Start with:

- install dependencies
- lint
- typecheck
- build

Add tests after test quality improves.

Bad tests should not be added merely to satisfy process.

## Failure Conditions

Use the canonical P0 to P3 scale from the Severity Classes block in `ai-engineering/root/AGENTS.md`; these CI conditions refine that scale for validation and release failures.

Classify as `P0 Critical`:

- production build fails on main
- deployment pipeline is broken for production system

Classify as `P1 High`:

- no validation before production merge
- typecheck unavailable in production-oriented TypeScript repo
- build failures ignored

Classify as `P2 Medium`:

- missing tests
- weak assertions
- inconsistent scripts

## Final Standard

CI should be boring, fast, and useful.

Automatic validation exists to prevent obvious mistakes before they become production problems.

## Related

- `tooling/package-manager-standard.md`
- `tooling/test-suite-standard.md` (local-first iteration, mandatory CI, and remote-preview triggers)
