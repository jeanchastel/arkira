# Operating Directive

## Prime directive

Complete the accepted outcome with the least operator intervention. Choose the
simplest reliable implementation, including deletion or replacement when justified. Take an action only to close a named acceptance,
safety, or verification gap. Record every other finding once. Then continue or
stop.

A safety gap means possible data loss, security exposure, unauthorized remote
mutation, or false verification evidence. General curiosity, possible cleanup,
and adjacent improvement are not safety gaps.

## Decision rule

Before each material action, name the acceptance, safety, or verification gap
it closes. If the action closes none, do not take it. Record a useful adjacent
finding once in the handoff or backlog, then return to the accepted outcome.

Pause only for a material product decision, an approval-gated mutation, required
local UI acceptance, or a terminal evidence failure. Do not pause for a routine
plan recap, a healthy agent, an already answered question, or a lower priority
finding.

Stop when every acceptance is satisfied, required evidence matches the current
candidate, and no safety gap remains. Time alone does not force a stop. A
repeated investigation that yields no new acceptance-relevant evidence does.

## Verification budget

- Use the least repeated exact proof that can falsify the changed behavior.
- For a behavior change, observe one focused expected failure, make the change,
  then run that same exact suite once to green.
- Reuse terminal green evidence until its candidate, command, dependency, or
  relevant external state changes.
- Do not add a test when an existing test already proves the same failure.
- Do not add behavioral tests for prose-only edits.
- During development, run one registered suite with
  `scripts/run-all-tests.sh --suite <id>`. Do not run its broader group.
- Normal and Elevated local certification use the bound focused check, the
  deterministic tree minimum, and the required independent review. Elevated
  adds only its named surface proof and tree-bound delivery authorization.
- Required pull request CI is the single broad inventory run. A full local
  inventory requires an explicit operator request.

Every new test must name a distinct failure that it prevents. Delete or merge a
test that only repeats another proof.

## Goal boundary

`/goal` owns one bounded outcome, one Task contract, one atomic candidate, and
one pull request. Internal agent chunks may be parallel when their write scopes
are disjoint. Conversation boundaries do not interrupt an active goal. Manual
feature, remediation, and review workflows retain their semantic boundaries
outside `/goal`.
