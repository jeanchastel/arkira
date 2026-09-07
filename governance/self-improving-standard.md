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

- Off by default. Reflection spends model tokens, and autonomous apply is a
  second opt-in switch.
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
2. Run the CLAUDE.md change guard (`.github/scripts/check-claude-md-change.sh`). It
   fails if the change removes governance-critical content (approval gates,
   "Do Not" rules, security, RLS, severity markers), forcing a human to confirm the
   removal is intentional.
3. Get a cross-agent review per `ai-engineering/workflows/review-pass.md`: a reviewer
   (Codex or Claude) confirms the change does not contradict `AGENTS.md`, weaken a
   gate, or add a harmful instruction.
4. Commit and open a PR for human acceptance.

The reflect hook only proposes. The guard, the review, and human acceptance are
three independent checks before any self-improvement lands.

### Autonomous tier

**Status: NOT OPERATIONAL.** `scripts/self-heal.sh` is not registered on
SessionStart. Direct and observe invocations are report-only and cannot apply,
revert, branch, stage, or commit changes. Proposals remain human-reviewed under
the standard change flow above.
