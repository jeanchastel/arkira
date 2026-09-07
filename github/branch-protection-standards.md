# Branch Protection Standards

## Purpose

Define the minimum GitHub governance controls for Arkira-governed repositories.

## Scope

Applies to:

- production repositories
- customer-facing systems
- internal operational systems
- AI-assisted software repositories

## Required Branch Protection

Protect:

- `main`
- `master`
- production release branches where applicable

## Required Controls

Repositories should:

- disallow direct pushes to protected branches
- require pull requests
- require successful validation checks
- require review before merge
- preserve deployment rollback capability

Classic GitHub branch protection is the required remote mechanism. It must
require a pull request, strict required status checks, and conversation
resolution; block force pushes and deletions; enforce protection for
administrators; and set `restrictions` to `null`. The required approval count
may be zero only when the repository's separate review workflow supplies the
review requirement.

## Required Validation Checks

Where applicable, require:

- lint
- typecheck
- tests
- production build
- dependency audit

before merge.

## Pull Request Standards

Pull requests should:

- remain focused in scope
- avoid unrelated cleanup
- summarize validation performed
- identify deployment implications
- identify rollback considerations

## Do Not

- merge unvalidated production-impacting changes
- bypass review casually
- combine unrelated remediation work
- deploy experimental branches directly to production

## Deployment Discipline

Production deployment should occur:

1. after successful validation
2. after review
3. after deployment impact review
4. after rollback considerations are understood

## AI-Assisted Development Rules

AI-generated changes require:

- explicit review
- validation verification
- operational scrutiny
- scope discipline

AI speed does not reduce governance requirements.

## Validation Language

Use explicit language:

- `Validation required:`
- `Validation performed:`
- `Validation not performed:`

Do not imply successful validation without proof.

## Final Standard

Governance exists to reduce:

- uncontrolled deployment risk
- architectural drift
- operational instability
- remediation chaos
- hidden regression risk
