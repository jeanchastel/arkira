---
name: coding
description: Canonical Arkira coding guidance for planning, implementation, and review of a bounded repository outcome. Reuse existing solutions and finish the accepted delivery unit.
---

# Coding a bounded outcome

Before implementation, state the requested result, observable acceptance criteria, delivery target,
owned paths, and non-goals. Reuse an approved plan. Group related agent subtasks into one reviewable
integration unit before creating branches. One integration owner owns final edits, evidence, and
publication; delegated units return changes and evidence, not separate releases.

Inspect existing components, utilities, installed packages, standard libraries, and native platform
features first. Briefly assess fit, maintenance, portability, accessibility, licensing, and integration
cost. Choose once sufficient evidence supports a suitable option. For suitable frontend work,
prefer Base UI with Tailwind or a comparable portable solution; respect an existing suitable stack
and explicit requirements. Do not migrate a working repo merely to standardize a preference.

Reuse maintained accessible primitives for dialogs, menus, forms, focus management, and keyboard
behavior. Verify the actual interaction, labels, focus restoration, error state, and relevant screen
sizes with installed repo E2E tooling. Do not hand-roll common UI behavior or infrastructure that an
existing portable solution already provides. Custom code should address a stated product-specific
gap with minimal new surface. Avoid wrappers, abstractions, or dependencies without a concrete need.

During development, use focused checks that can expose the changed behavior. Review the combined
candidate independently once. Broader integration validation belongs at the integration boundary;
consume its authoritative result later while revision, relevant configuration, dependencies, and
merge context remain valid. Revalidate only what subsequent changes invalidate. Deployment checks
verify the intended revision and target environment plus remaining acceptance criteria, not an
automatic repeat of the full suite.

Follow adjacent dependencies only when they directly block acceptance or verification. Record other
findings once for later. Do not add unrelated refactors, migrations, speculative infrastructure, or
new features. Once acceptance passes, finish the requested delivery target and stop.

Planning and review use this same source. No extra generic approval or mechanical validation layer
is required; add a mechanical check only for a demonstrated recurring violation it can detect reliably.
