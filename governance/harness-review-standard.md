# Harness Review Standard

Status: canonical. Synced to product repos via `/arkira-sync`.

## Why

As models improve, instructions written for an older model become constraints. A
CLAUDE.md rule that helped a weaker model can hold back a stronger one, and skills
or hooks built to compensate for past limitations become overhead once those
limitations are gone.

## Cadence

Review the harness every 3 to 6 months, and whenever performance plateaus after a
major model release.

## What to review

- CLAUDE.md hierarchy: remove rules that compensate for limitations the current
  model no longer has; keep the root file to pointers and gotchas.
- Skills: retire or merge skills that duplicate native model ability; confirm
  descriptions still trigger and `paths:` still scope correctly.
- Third-party skills: re-review each third-party skill against
  [tooling/third-party-skills-standard.md](../tooling/third-party-skills-standard.md),
  confirm it is still pinned, the source is still allowed, and hooks are
  unchanged since the last review.
- Hooks: remove hooks that worked around tooling gaps now closed natively.
- Switches: retire switches whose behavior is now default or unnecessary.
- Downstream output quality: confirm the harness steers projects toward typed,
  maintainable, production-ready code with focused tests, explicit failure
  handling, minimal dependencies, and no generated scratch residue. Token savings
  never justify weaker correctness evidence or a hidden dependency blind spot.

## How

- Record what was removed and why in `VERSION.md`.
- Prefer deletion over accumulation; a smaller harness is faster and cheaper.
- Re-run the test and validation suites after pruning.

### Minimal-scope mandate

Every harness change must use the smallest viable patch that satisfies the
stated acceptance criteria. Before editing, name the requested outcome, the
minimal file set, and the focused evidence that will prove it. Do not add
generalized abstractions, speculative edge-case handling, extra workflow
ceremony, or unrelated cleanup.

Use the ponytail review as the default scope check. If the change passes its
focused acceptance checks, stop. Expand the scope only when a concrete test
failure, security concern, compatibility requirement, or explicit user request
requires it. Record the reason for any expansion in the implementation note or
review evidence.

This mandate applies to planning, implementation, review, and rollout. A plan
that cannot identify a minimal viable patch is not ready for implementation.

### Release bump file set

At release time, update `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`,
`.arkira/config.json`, the `README.md` badge, `VERSION.md`, and `CHANGELOG.md` together.
