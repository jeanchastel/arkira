# Sanitized Review Fixture: Bad

Author agent: Codex
Reviewer agent: Claude

## Findings

- P1 `ai-engineering/evals/run-eval.sh`: the runner requires a network LLM call
  for every criterion.

## Verdicts

The finding is not supported by the fixture. Deterministic criteria can run
offline.
