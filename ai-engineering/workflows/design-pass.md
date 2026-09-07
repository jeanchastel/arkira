# Design Pass Workflow

## Objective

Turn an Elevated request, or a Normal request that materially benefits from design, into an
approved spec and executable plan without changing application code. Quick work skips this pass.
Tier selection follows [tier-routing.md](./tier-routing.md).

## Inputs

- The natural-language request, repository, constraints, and known acceptance criteria.
- Existing product idea, validation, architecture, and audit material relevant to the request.
- The resolved Planner role. A concrete Planner is dispatched through
  `ai-engineering/runtime/role-run.sh planner planning`; `host-session` plans inline.

## Constraints

- Do not modify application code, dependencies, migrations, infrastructure, CI, or deployment.
- Decompose independent subsystems before planning implementation.
- Preserve named scope, protected files, prior work, and approval gates.
- Ask for human decisions only when they materially alter scope, architecture, or risk.

## Process

1. Classify the preliminary tier from requested paths and scope.
2. Read controlling context and relevant existing design material.
3. Map the affected system and its invariants. Use read-only exploration for a genuinely broad
   subsystem; do not create reports for trivial lookup.
4. Resolve material unknowns and present tradeoffs with one recommendation.
5. Write `docs/specs/YYYY-MM-DD-<topic>.md` with concrete acceptance criteria, exclusions, and
   approval-gated surfaces. For user-facing work, define the intended journey and the relevant
   responsive, accessibility, interaction, loading, empty, and error states.
6. After human approval, write `docs/plans/YYYY-MM-DD-<topic>.md` with exact files, bounded tasks,
   test-first verification, ownership, and handoff points. Add numbered conversation chunks when
   implementation needs more than one semantic unit. Each chunk contains one to three cohesive
   tasks, one focused proof, and a clean stopping condition.
7. Self-check the plan against every spec requirement. Remove placeholders and duplicate ceremony.
8. Seal the reviewed plan as the design handoff. Stop before implementation so the feature pass can
   begin in a fresh conversation. An active `/goal` records the plan in durable goal state and
   continues without a routine conversation pause.

## Stop Conditions

Stop for human direction when scope cannot be reduced, approval-gated behavior is undecided,
acceptance cannot be made concrete, or the requested design conflicts with controlling architecture.

## Required Output

- Spec and plan paths.
- Tier and its triggers.
- Decisions, open risks, and the exact implementation handoff.
- Numbered conversation chunks and the sealed design boundary when implementation is not Quick.
