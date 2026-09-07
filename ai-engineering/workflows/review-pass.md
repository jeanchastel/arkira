# Review Pass Workflow

## Objective

Verify the exact candidate in proportion to risk. Reject AI slop.
Return publish authority only after the required evidence is complete.
Tier selection follows [tier-routing.md](./tier-routing.md).

Manual review begins in a fresh conversation with the sealed candidate handoff. A dispatched
Verifier already provides an isolated context and satisfies this conversation boundary.

Use the callable `arkira:coding` skill from the resolved plugin for reuse and task discipline.

## Common Checks

Every tier:

1. Read the request and controlling spec or plan.
2. Inspect the actual diff and preserve existing work outside scope.
3. Apply the repository's AI Slop Detection and surgical-change rules.
4. Verify tests are meaningful, failure paths are covered, and reported commands match reality.
5. When UI changed, inspect the rendered journey at relevant viewports and verify interaction,
   responsive behavior, accessibility, loading, empty, and error states. Use the applicable
   trigger-matched UI capability; do not impose UI ceremony on non-UI changes.
   When customer-facing copy changed, verify rendered UI, transactional email, and notification copy
   contains no em or en dashes.
6. Run post-diff routing. Continue under the highest resulting tier.
7. Stage the exact intended candidate. Candidate-gate certification binds the focused evidence,
   deterministic tree minimum, and code-quality review to that tree. Full CI is separate and explicit.
8. Before publish, verify `git status --porcelain` and relevant history. Reject unauthorized
   commits, staging, or remote mutations from either authoring mode.

When the candidate requires a full local proof, run `candidate-gate.sh validate --repo . --full-ci`
once after staging. Certification reuses matching proof. Run it again only after a documented
invalidation.

## Quick

Inspect the complete small diff and run focused tests plus any cheap directly related static check.
The gate runs the deterministic Quick minimum. Quick has no model review.

## Normal

Perform the common checks, then certify the complete staged candidate once. The default runs the
bound focused check and deterministic tree minimum, then dispatches one configured code-quality
Verifier. If that Verifier is unavailable, attach one tree-bound host-review record. Do not run
baseline or full CI locally unless the operator explicitly asks for a full local proof.

## Elevated

Perform the Normal checks plus:

- Run the surface-specific security, data, migration, payment, auth, infrastructure, secrets, or CI
  check that triggered Elevated.
- Candidate-gate dispatches a distinct second-opinion Verifier through
  `role-run.sh verifier structured_reviewing`. It must resolve to a concrete provider and model,
  never `host-session`, and must not be the author.
- Resolve all blocking findings and rerun invalidated evidence against the changed candidate.
- P2 and P3 findings are advisory. They do not require another implementation or review pass.
- Require the exact candidate's tree-bound validation record and concrete independent Verifier evidence. These are the authorization to publish and arm GitHub auto-merge.

## High-assurance

High-assurance is experimental and unsupported. It is available only when
`high_assurance_release` is enabled and must satisfy Elevated first. The legacy signed release-trust
workflow remains reference machinery under `ai-engineering/release-trust/`; it is not authoritative
release proof while the reviewer identity, model binding, and independence defects tracked in
`docs/specs/2026-07-22-release-trust-producers.md` remain open. Never describe its output as a trusted
release certificate.

## Failure Rules

- Missing, timed-out, stale, or candidate-mismatched evidence fails closed.
- Focused evidence, the deterministic tree minimum, and code-quality review form the ordinary
  staged-tree certification path for Normal and Elevated.
- A substantive edit after review invalidates that review.
- The host orchestrator owns commit, push, deployment, database, and publication operations.
- Required remote PR CI remains mandatory after publication and is the broad inventory proof.
  GitHub completes native auto-merge only after those strict checks pass. A changed head, failed
  check, conflict, or missing permission leaves the PR open for a reported human decision.

## Required Output

- Final tier and trigger evidence.
- Candidate identity and working-tree state.
- Findings with direct file evidence.
- Exact checks and terminal outcomes.
- Auto-merge status or the exact reported delivery blocker.
- Go or no-go recommendation.
- Closed review handoff after the recommendation is recorded.
