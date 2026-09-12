# AI Agent Governance

<!-- ARKIRA:MANAGED START id=governance-intro v=1 sha=289ac8670aeda92469d63c6a6ca3942e41ca3b57b52e453f6ff4e4d1678a90b5 -->
This repository uses AI agents for review, remediation, validation, and reporting. Agents must preserve application behavior unless the user explicitly asks for an implementation change.
<!-- ARKIRA:MANAGED END id=governance-intro -->

<!-- ARKIRA:MANAGED START id=operating-directive v=1 sha=80dab411ca568f0363b77e68a64c26e6f5fc21d668a9ca21db520e55c7be6a64 -->
## Operating Directive

Complete the accepted outcome with the least operator intervention. Make the smallest verified change. Take an action only to close a named acceptance, safety, or verification gap. Record every other finding once. Then continue or stop.

Use one focused red and one focused green for changed behavior. Reuse terminal evidence until its inputs change. Normal and Elevated local certification do not duplicate the broad pull request CI inventory. Run a full local inventory only when the operator explicitly requests it. See `governance/operating-directive.md`.
<!-- ARKIRA:MANAGED END id=operating-directive -->

<!-- ARKIRA:MANAGED START id=governance-summary v=4 sha=e6404656ce2ab5492cb91a8b406a59786d9a5f38ffeeb13b80ef25a6893f6a5b -->
## Universal Rules

- Treat `/reports` as the source of record for audit context and remediation priority.
- Do not modify application code, package files, migrations, infrastructure, or generated files unless the task explicitly allows it.
- Do not run migrations, reset databases, delete data, rename files, or perform destructive Git operations without explicit approval.
- Preserve existing user changes. If the worktree is dirty, inspect the relevant files before editing and avoid unrelated cleanup.
- Keep changes small, reviewable, and tied to a stated issue, report, or user request.
- Do not use em or en dashes in customer-facing product copy, including rendered UI, transactional email, and notifications. They are permitted in documentation, plans, reports, and internal prose.
- A skill is guidance; an agent is delegated isolated-context execution; a skill wires at most one agent.
- The active host owns direct implementation and orchestration by default.
- A dispatched Executor owns only the scope that the active host delegates.
- Delegate through `ai-engineering/runtime/role-run.sh executor code_editing`.
- Do not invoke a legacy provider companion for harness implementation. Provider-specific shortcuts bypass role resolution, sandbox guarantees, job lifecycle, and retry accounting.
- Direct work never fabricates an Executor receipt.
- Neither authoring mode permits deployment or arbitrary remote mutation without existing authority.
- Stage the intended candidate before publication. Run `candidate-gate.sh certify` for that exact tree.
- A certified candidate has standing host authority to create its `arkira/<workflow>-<unit>` branch, commit, push, create a GitHub pull request, and arm native squash auto-merge. This applies to Quick, Normal, and Elevated only after exact-tree validation and tier-required independent review.
- Never push directly to `main`. A changed PR head, merge conflict, base drift, missing GitHub permission, failed check, or no-go leaves the PR open and is reported. Do not auto-fix or retry.
<!-- ARKIRA:MANAGED END id=governance-summary -->

## Roles And Tooling

- The Planner owns design direction, architecture, scope, and executable instructions.
- The active host owns direct implementation, focused tests, focused validation, and orchestration.
- A dispatched Executor owns its delegated implementation scope and returns a commit-ready handoff. It never commits or publishes.
- The Verifier rereads the actual tree, applies the clean-code checklist, and runs the checks required by the final tier.
- The host orchestrator owns Git, GitHub, deployment, database, and final publication operations.
- When GitHub, Vercel, Supabase, or similar project plugins/connectors are available, agents should prefer them for current repository, deployment, and database context over ad hoc guessing or stale assumptions.
- Plugin availability does not override approval gates. Mutating remote services, deployment configuration, schemas, data, CI, releases, or repository settings still requires explicit human approval, except the exact GitHub PR and auto-merge operations authorized by a certified candidate and the repository auto-merge setting applied by `/arkira-sync --apply`.
- The default deployment target is a GitHub pull request. Do not invoke a Vercel CLI, API, or deployment action unless the user explicitly names Vercel.
- A request to deploy to live main explicitly authorizes merging the validated, green pull request through GitHub. It never authorizes a direct push to `main`. A GitHub integration may deploy after merge without an agent invoking Vercel.

Code context. Before Grep plus Read on an unfamiliar area, you may run
`semble search "<question>" .` once; add `--content all` in a repository that is
mostly documentation. Before editing a symbol used outside its file, you may call
the `codebase-memory` MCP tools: `index_repository` first, then `trace_path` or
`detect_changes`. Fall back to Grep when either tool is unavailable.

<!-- ARKIRA:MANAGED START id=model-optimization v=2 sha=0fe99a9d85a31d1924972e15ac3b5bc2076b72246cf8fa256898beb76949b467 -->
## Model Optimization

Follow `governance/model-selection-standard.md` in the resolved Arkira plugin. Choose models and delegation for verified quality and the complete task's elapsed time and tokens, including review and rework. Monetary cost is secondary unless the operator sets a budget.
<!-- ARKIRA:MANAGED END id=model-optimization -->

## Workflows

The repository recognizes four tier-aware workflows under `workflows/`.

- `workflows/design-pass.md`: Planner design for Elevated or useful Normal work.
- `workflows/feature-pass.md`: direct or delegated implementation, test-first.
- `workflows/remediation-pass.md`: consolidated delivery of compatible approved findings.
- `workflows/review-pass.md`: tier-proportionate Verifier review.

Artifacts produced by the design pass live under:

- `docs/specs/YYYY-MM-DD-<topic>.md`
- `docs/plans/YYYY-MM-DD-<topic>.md`

Quick work may use direct approved instructions. Normal and Elevated work use the spec and plan when
the design pass requires them.

<!-- ARKIRA:MANAGED START id=session-segmentation v=4 sha=4a8e9ec9d17b69641fa7e7b50551faa8b8811249ea60599952861aad54001559 -->
## Session Segmentation

- Treat one conversation as one semantic work unit. Durable artifacts and a sealed handoff, not chat history, carry work forward.
- Design ends after the approved, reviewed plan. Feature plans name independently verifiable conversation chunks of one to three cohesive tasks. Remediation uses one coherent batch of compatible approved findings per conversation.
- Manual review starts in a fresh conversation or an isolated Verifier context.
- Start the unit lease with `scripts/session-handoff.sh start`. At a boundary or after 90 minutes, finish the current atomic operation, seal the handoff, and stop before the next unit.
- An explicit `continue` reason grants only a 30-minute grace period.
- When the operator says `Resume Arkira handoff`, run `scripts/session-handoff.sh resume`, reconcile stale Git facts before mutation, and continue only the recorded Next action.
- `/goal` owns one bounded outcome through pull-request delivery without routine conversation pauses. Its private runtime state, not a chat boundary, carries internal chunk progress.
- An operator-approved remediation consolidation may prepare the next already-inventoried batch in a separate branch and worktree while the current replacement pull request waits on hosted checks. Each batch retains separate scope, evidence, review, and publication boundaries.
<!-- ARKIRA:MANAGED END id=session-segmentation -->

## Cross-Agent Review

Elevated work requires a distinct concrete second-opinion Verifier that did not author the candidate.
Quick may use the configured `host-session` Verifier. Normal uses it only for one tree-bound host
review when a concrete Verifier is unavailable. Any substantive Verifier edit makes that Verifier an
author and invalidates the prior review. See `workflows/review-pass.md`.

<!-- ARKIRA:MANAGED START id=approval-gates v=2 sha=b26f4c32d902b28869ee83879bc157665dad2db996db9fe607aecc134b7dbd3b -->
## Approval Gates

Require explicit approval before:

- Editing schema, migrations, authentication, authorization, payment, email, cron, or deployment behavior.
- Installing, upgrading, or removing dependencies.
- Running commands that mutate remote services, production data, or cloud configuration.
- Creating deployment workflows, or changing CI, GitHub Actions, or release automation outside the approved Arkira automatic-delivery standard.
- Changing package manager files, lockfiles, or environment files.
<!-- ARKIRA:MANAGED END id=approval-gates -->

<!-- ARKIRA:MANAGED START id=severity-classes v=1 sha=322111f695f802412300aca7c62bbae3ab8bd1997e289c01e51f1c8136e82295 -->
## Severity Classes

- `P0 Critical`: external launch, disaster recovery, data integrity, or platform-control blocker.
- `P1 High`: fix before production reliance unless the risk is explicitly accepted.
- `P2 Medium`: real risk or maintainability debt that should follow P0/P1 work.
- `P3 Low`: hardening, hygiene, cosmetic, or speculative until verified.

Use `reports/remediation-backlog.md` as the current normalized severity baseline.
<!-- ARKIRA:MANAGED END id=severity-classes -->

<!-- ARKIRA:MANAGED START id=ai-slop-detection v=1 sha=adc784d126b93701ae174956f81c9a0f400a165509ae78504c0ab7388eb5bac8 -->
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
<!-- ARKIRA:MANAGED END id=ai-slop-detection -->

## Branch Expectations

- Work on a dedicated branch for implementation work.
- Use a `codex/` branch prefix unless the user requests another convention.
- Keep commits focused by coherent remediation batch or governance change.
- Do not commit secrets, local environment files, generated build output, or agent scratch files.

## Publishing And Acceptance Helpers

- `scripts/create-pr.sh` is considered a publishing helper.
- Publishing actions may be automated only after successful validation, a completed cross-agent review per `workflows/review-pass.md`, a clean worktree, reviewed diff, and completed commit.
- `scripts/complete-candidate.sh` owns the normal commit, PR creation, and GitHub native auto-merge path for an exact certified candidate.
- `scripts/merge-current-pr.sh` is manual recovery only. Native auto-merge waits for required GitHub checks and resolved threads without a human merge action.
- The authoring role reports intended commit boundaries. It does not commit, push, create pull requests, or execute merge helpers.
- The host orchestrator owns publishing after exact-candidate review. A changed head, failed check, conflict, base drift, or missing permission leaves the PR open and is reported without an automatic retry.
- Publication certification and GitHub merge enforcement are separate operational trust boundaries.

<!-- ARKIRA:MANAGED START id=autonomous-apply-tier v=1 sha=803ef17d2c18c4139c09acfc5edbdf8847f5afc28128dcd352905534303931c5 -->
## Autonomous Apply Tier (Status: Not Operational)

Self-heal is not operational in this release. It is not registered on
SessionStart, and its observe route is report-only. No proposal is reverted,
applied, branched, committed, or merged automatically. See
`governance/self-improving-standard.md` for the containment contract.
<!-- ARKIRA:MANAGED END id=autonomous-apply-tier -->

## Reporting Expectations

- State what changed, which files changed, and how validation was performed.
- If validation was not run, say why.
- Distinguish verified findings from assumptions, operator questions, and speculative risks.
- Preserve audit disagreements instead of merging them away.

## Audit Workflow Rules

- Start from the committed reports before re-auditing: `initial-audit-claude-code.md`, `initial-audit-codex.md`, `audit-synthesis.md`, and `remediation-backlog.md`.
- Treat the current Codex audit file as a placeholder until real findings are added.
- Validate P0/P1 fixes with targeted tests or reproducible checks before broad refactors.
- Prefer test-first remediation for time tracking, setup, reminders, and other high-risk paths.

<!-- ARKIRA:MANAGED START id=intent-layer v=1 sha=9713d3d9d81c501ad546dff94a134e209aaa79e0fb1cc91030417cef0dbe6533 -->
## Intent Layer

Context files form a hierarchy of `AGENTS.md` nodes:

- `AGENTS.md` is the single shared, tool-agnostic root context every agent reads. `CLAUDE.md` and `CODEX.md` are role overlays that point at it and never duplicate its normative content. Build the hierarchy from child `AGENTS.md` files in subdirectories, never from extra `CLAUDE.md` or `CODEX.md` files below the root.
- Every node opens with a READ-FIRST directive and stays under 4k tokens.
- Add a child `AGENTS.md` when a directory exceeds roughly 20k tokens, when responsibility shifts to a new domain, or for a cross-cutting concern placed at the lowest common ancestor. Document hidden contracts and invariants in the nearest ancestor node.
- Do not create nodes for every directory, simple utilities, or test folders unless genuinely complex.

Rationale and examples: <https://github.com/jeanchastel/arkira-labs-standards/blob/main/governance/intent-layer-standard.md>
<!-- ARKIRA:MANAGED END id=intent-layer -->
