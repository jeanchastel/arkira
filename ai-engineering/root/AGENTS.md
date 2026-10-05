# AI Agent Governance

<!-- ARKIRA:MANAGED START id=governance-intro v=1 sha=289ac8670aeda92469d63c6a6ca3942e41ca3b57b52e453f6ff4e4d1678a90b5 -->
This repository uses AI agents for review, remediation, validation, and reporting. Agents must preserve application behavior unless the user explicitly asks for an implementation change.
<!-- ARKIRA:MANAGED END id=governance-intro -->

<!-- ARKIRA:MANAGED START id=operating-directive v=1 sha=80dab411ca568f0363b77e68a64c26e6f5fc21d668a9ca21db520e55c7be6a64 -->
## Operating Directive

Complete the accepted outcome with the least operator intervention. Make the smallest verified change. Take an action only to close a named acceptance, safety, or verification gap. Record every other finding once. Then continue or stop.

Use one focused red and one focused green for changed behavior. Reuse terminal evidence until its inputs change. Normal and Elevated local certification do not duplicate the broad pull request CI inventory. Run a full local inventory only when the operator explicitly requests it. See `governance/operating-directive.md`.
<!-- ARKIRA:MANAGED END id=operating-directive -->

<!-- ARKIRA:MANAGED START id=governance-summary v=5 sha=48eede720c2a5ad1c30bedf131ba834b08e532eff7fb6923384c7683ae554f0e -->
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
- Delegate direct, ad hoc host work through `ai-engineering/runtime/role-run.sh executor code_editing`. `/goal`-driven autonomous work instead requires the receipted, contract-bound entrypoint `bin/arkira task <repo> dispatch --contract <file>`.
- Do not invoke a legacy provider companion for harness implementation. Provider-specific shortcuts bypass role resolution, sandbox guarantees, job lifecycle, and retry accounting.
- Direct work never fabricates an Executor receipt.
- Neither authoring mode permits deployment or arbitrary remote mutation without existing authority.
- Stage the intended candidate before publication. Run `candidate-gate.sh certify` for that exact tree.
- A certified candidate has standing host authority to create its `arkira/<workflow>-<unit>` branch, commit, push, create a GitHub pull request, and arm native squash auto-merge. This applies to Quick, Normal, and Elevated only after exact-tree validation and tier-proportionate review per `workflows/review-pass.md`.
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

<!-- ARKIRA:MANAGED START id=model-optimization v=2 sha=81d093338356b67a9713269f6090eb97b23ea769cd4cdb6402759886428a332c -->
## Model Optimization

See Model Optimization in governance/root-agents.md in the resolved Arkira plugin.
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

Follow the tier-proportionate Verifier rule in `workflows/review-pass.md`.

<!-- ARKIRA:MANAGED START id=approval-gates v=2 sha=b26f4c32d902b28869ee83879bc157665dad2db996db9fe607aecc134b7dbd3b -->
## Approval Gates

Require explicit approval before:

- Editing schema, migrations, authentication, authorization, payment, email, cron, or deployment behavior.
- Installing, upgrading, or removing dependencies.
- Running commands that mutate remote services, production data, or cloud configuration.
- Creating deployment workflows, or changing CI, GitHub Actions, or release automation outside the approved Arkira automatic-delivery standard.
- Changing package manager files, lockfiles, or environment files.
<!-- ARKIRA:MANAGED END id=approval-gates -->

<!-- ARKIRA:MANAGED START id=severity-classes v=2 sha=05b8a0f8b961e5227e9594ee9c461a100ff24e6bf88db6df5391cf0c84b003bb -->
## Severity Classes

See Severity Classes in governance/root-agents.md in the resolved Arkira plugin.
<!-- ARKIRA:MANAGED END id=severity-classes -->

<!-- ARKIRA:MANAGED START id=ai-slop-detection v=1 sha=62daffb7ef8713c8ada41753e2c442eb0226d7ccbb4371fcac87d019bc3c827b -->
## AI Slop Detection

See AI Slop Detection in governance/root-agents.md in the resolved Arkira plugin.
<!-- ARKIRA:MANAGED END id=ai-slop-detection -->

## Branch Expectations

See Branch Expectations in governance/root-agents.md in the resolved Arkira plugin.

## Publishing And Acceptance Helpers

See Publishing And Acceptance Helpers in governance/root-agents.md in the resolved Arkira plugin.

<!-- ARKIRA:MANAGED START id=intent-layer v=1 sha=ea70d8a4311ef6eacf86fb53c76d7fa441aa08acce1d75ff075bc5a2f117cb25 -->
## Intent Layer

See Intent Layer in governance/root-agents.md in the resolved Arkira plugin.
<!-- ARKIRA:MANAGED END id=intent-layer -->
