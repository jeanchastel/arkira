# Next Steps Standard

Status: canonical. Synced to product repos via `/arkira-sync`.

## Switch

`verbose_next_steps` in `ai-engineering/bootstrap/switches.json`. Default on.

## Rule

When `verbose_next_steps` is on, every response that finishes or pauses a task
ends with a `## Next` block in this exact shape:

```text
## Next
- **Recommended:** <one sentence naming the next move>
- **Alternate:** <one or two sentences, optional>
- **Gate:** <any approval the operator must clear, or "none">
```

The block sits at the very end of the response. It is the last thing the
operator reads.

## Field Rules

- **Recommended.** One sentence. Names the next move concretely. Includes the
  command or action if there is one. Not a question.
- **Alternate.** Zero, one, or two alternates. Each one sentence. Use when the
  recommended move is not the only sensible next step. Skip the line entirely
  if there is no real alternate.
- **Gate.** Names any human approval the operator must clear before the
  recommended move can execute (merge approval, security review, deploy
  window). If none, write `none`.

## Exemptions

The trailer is omitted, even when the switch is on, in three cases:

- mid-turn clarifications before any work begins
- pure acknowledgements ("got it", "understood")
- single-line answers to single-line questions

If the response touches code, runs tools, opens a PR, or pauses on a decision
point, the trailer applies.

## Off-State

When `verbose_next_steps` is off, the trailer is omitted entirely. The
response ends where the task ends, no `## Next` block.

## Related

- `governance/agent-swarm-standard.md`
- `governance/role-contracts.md`
