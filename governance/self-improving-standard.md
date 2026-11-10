# Self-Improving CLAUDE.md Standard

Status: canonical. Synced to product repos via `/arkira-sync`.

## Switch

`self_improving_claude_md` in `ai-engineering/bootstrap/switches.json`. Default off.

## Rule

When `self_improving_claude_md` is on, a `Stop` hook reflects on a session that
changed tracked files and proposes `CLAUDE.md` edits. The proposal is written to
`.arkira/proposals/claude-md/` for human review. The hook never edits `CLAUDE.md`
and never commits. A `SessionStart` hook prints a one-line notice when proposals
are pending.

## Boundaries

- Off by default. Reflection spends model tokens.
- Proposer scope is context guidance. Reflection writes proposal patches under
  `.arkira/proposals/claude-md/`; it never edits live files and never commits.
- Automated apply is disabled for this release. Every proposal routes to human
  review regardless of shape, confidence, or prior classification.
- Background and bounded. Reflection runs detached with a timeout, so it never
  delays a session, and is throttled so rapid stop cycles do not stack.

## Review

Proposals accumulate in `.arkira/proposals/claude-md/` (gitignored). Human-gated
items stay there until reviewed. Apply by hand the edits that capture durable
conventions, and delete the files once handled.

## Safety Gate

A proposal is advisory. It is never committed automatically, and self-improvement
must never weaken the system. Applying a proposal follows the normal change flow:

1. Apply the edit on a branch, never directly to `CLAUDE.md` on the main branch.
2. Get a cross-agent review per `workflows/review-pass.md`: a reviewer
   (Codex or Claude) confirms the change does not contradict `AGENTS.md`, weaken a
   gate, remove governance-critical content, or add a harmful instruction.
3. Commit and open a PR for human acceptance.

The reflect hook only proposes. The review and human acceptance are two
independent checks before any self-improvement lands.
