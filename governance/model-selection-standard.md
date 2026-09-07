# Model Selection Standard

Status: canonical. Runtime defaults live in
`ai-engineering/runtime/model-catalog.json`; adapters contain only native invocation mappings.

Choose the model likely to finish the complete task correctly with the least total time and tokens.
Include planning, context transfer, review, tests, retries, and rework. Monetary cost is secondary
unless the operator sets a budget. Quality, security, and verified completion are acceptance gates.

Use one capable agent by default. A frontier model is appropriate at the outset for coupled,
uncertain, security-sensitive, or cross-cutting work when it can avoid several weaker attempts.
Use a faster model for bounded investigation or mechanical work when its output can be checked.
Do not infer efficiency from model size, price, novelty, or an isolated first-response timing.

## Defaults and escalation

The canonical catalog sets ordinary planning and independent review to Claude's `sonnet` alias,
and implementation to `gpt-5.6-sol`. Native adapter defaults use medium effort for planning and
implementation, low for bounded reading/test execution, and high for independent structured review.
Normal review may use the configured Verifier at low effort. `quick_model` defaults to that same
Verifier, not an automatic weaker-model substitution.

For a complex plan, coupled implementation, unresolved failure, or adversarial review, use the
catalog's frontier escalation if the invoking runtime exposes it. Astra/xhigh and Opus/high are
explicit choices, not mandatory for every task. Honor an explicit operator model/effort request.
If those runtime settings are exposed, verify them; report inability to verify otherwise. A prompt
cannot change host runtime settings.

A dispatch requires a question/objective, owned paths, necessary context, expected output,
acceptance evidence, model, effort, and stopping condition. Retain the raw evidence behind a short
integration summary. The coordinating agent remains responsible for the combined result.

## Availability and fallback

Run `node <harness>/ai-engineering/runtime/models.mjs [model effort]` during Codex model selection
or tool maintenance. It reads native `model/list`, including hidden entries, and rejects an absent
model or unsupported effort without substituting another model. Discovery is not execution proof.
Use Claude's native `/model` picker and provider result `modelUsage`; aliases may resolve differently
by account/provider. Do not add an announced model to usable defaults without runtime access evidence.

The current environment's availability evidence and platform differences are recorded in
`reports/2026-09-05-sdlc-delivery.md`. That dated report is evidence, not a second routing catalog.
Do not copy a full provider catalog into adapters or per-repo instructions.

If a requested model is unavailable, name the failure and select an explicit accessible alternative
only within the operator's instructions. Never silently substitute. Escalate after a concrete failed
or incomplete result; do not mechanically exhaust weaker tiers first. Reuse valid peer results.
Unavailable credentials, exhausted credits, and unsupported runtimes require a visible blocker.

## Records

Role results, private job records, and receipts retain requested provider/model/effort and timings.
Provider output is authoritative for observed model and token usage. An invocation flag proves what
was requested, not what a provider actually executed. Missing observed effort or usage remains
unreported. Preserve cache-read and cache-creation tokens in whole-task totals and distinguish them
from newly processed tokens. Native resumed goal counters can reset or freeze; they are not a
substitute for complete run records. Do not build a benchmarking or telemetry service for selection.
