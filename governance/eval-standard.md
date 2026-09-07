# Eval Discipline Standard

Status: canonical. Release review enforcement is executable and independent of the legacy `eval_gate_enforcement` compatibility switch.

## Decision

Use evals for non-deterministic agent output and trajectories that tests cannot
score. Evals do not apply to deterministic application code that a unit test
covers. That boundary is hard.

The runner reports actual PASS, FAIL, or UNVERIFIED state. The
`eval_gate_enforcement` switch is retained for configuration compatibility but is
not consumed by executable logic in this release. It does not weaken the release
review path. Release review always requires an independent semantic judge and an
exact-candidate artifact before pull request creation.

## Rule

Prefer tests for fixed behavior and evals for scored judgment.

- P0: Never replace a deterministic unit test with an eval.
- P1: Prefer deterministic criteria before judge criteria.
- P2: Print a missing optional judge as SKIP. A rubric with `require_judge: true`
  returns UNVERIFIED and cannot satisfy release review.
- P3: Keep eval fixtures sanitized. No real secrets and no client PII.

## Rubric Anatomy

A rubric is JSON with an ordered `criteria` array and a `threshold` percent. Each
criterion has:

- `id`: stable identifier.
- `text`: observable assertion.
- `kind`: `deterministic` or `judge`.
- `weight`: optional integer, default 1.
- `hard_fail`: optional boolean. Failure blocks the gate regardless of score.
- `evidence_required`: optional boolean. Judge criteria that require evidence
  fail when evidence is missing.

Deterministic criteria use a `check` object:

- `grep`: match a pattern in a fixture file.
- `count`: count pattern matches with `min` and optional `max`.
- `schema`: validate required JSON paths with `jq`.
- `exit_code`: run a local command and compare the exit code.

Judge criteria use a `judge` object. The runner reads
`ARKIRA_EVAL_JUDGE_COMMAND` unless the criterion supplies a command. If no judge
command is configured, the criterion is skipped and not scored.

Judge verdicts use confidence 0 to 3:

- 0: no evidence.
- 1: weak or indirect evidence.
- 2: direct evidence from one source.
- 3: corroborated evidence from two or more sources.

A judge verdict passes only when `real` is true and confidence is at least 2.
Default to `real=false` when the judge cannot confirm the finding from evidence.

## Output And Trajectory

Output evals score the artifact: a spec, test file, review finding, or generated
patch. Trajectory evals score the path taken: whether raw tests ran, whether the
agent checked command output, or whether required local flags were used.

Review-pass finding confidence is an output eval. The goal.md rule to distrust
self-reported green is a trajectory eval.

## Workflow Gates

- Design-pass gates score spec completeness. P0 if a plan step is `TBD`,
  `implement later`, or states what without how.
- Feature-pass gates score test sufficiency. P0 if new behavior ships with no
  failing-first test.
- Review-pass requires structured direct evidence and an independent semantic
  judge. Caller-provided `real` or confidence strings are not release evidence.

## Fixture Layout

Per-unit evals live next to the workflow they grade:

```text
<unit>/evals/evals.json
<unit>/evals/targets.json
<unit>/evals/files/
```

`evals.json` contains cases shaped as
`{ id, name, prompt, expected_output, files, assertions[] }`. Each assertion is
`{ id, text, kind, hard_fail? }`. `targets.json` lists the model matrix by
provider. `files/` stores case inputs.

Shared regression fixtures live in `ai-engineering/evals/regression/`. Golden
fixtures live in `ai-engineering/evals/golden/`.

## Related

Prior art: promptfoo and the nine-skill eval workflow. They are referenced for
shape and vocabulary only. Do not vendor either framework into this plugin.
