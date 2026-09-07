---
name: ideate
description: Mine an operator's business or expertise, synthesize three to five candidate product directions, score each on a five-axis card, sharpen the winner, and write docs/product-idea.md. Use before the design pass when there is no decided product yet, to go from a founder's context to one sharpened direction. Not for adopting an existing external project; that is the intake skill.
origin: arkira (patterns adapted from buildgreatproducts/builder-os idea-generator, MIT)
reads: []
writes: [product-idea.md]
---

# Ideate

Turn an operator's business context and expertise into one sharpened product
direction. The runners-up are preserved so a direction can be reconsidered
later without rerunning the whole pass.

Patterns adapted from `buildgreatproducts/builder-os` (idea-generator), MIT
licensed. Adapted, not copied.

## Not the intake skill

`ideate` generates a net-new direction from nothing. `intake` re-homes an
existing external client project onto your own GitHub and Vercel. No functional
overlap, only the English word "intake" is close. If the operator already has a
project to adopt, use `intake`. If they have a business and no product yet, use
this.

## When to Use

- The operator has a business, expertise, or audience and no decided product.
- Before the design pass, to feed it a validated direction instead of a cold
  start.

Not for: a decided product that needs a spec (go straight to the design pass).
Not for: adopting an existing external project (use `intake`).

## Profile gate

None. This skill is profile-agnostic. It runs before `/arkira-init`, because a
greenfield idea may have no repo yet. It runs whether or not
`.arkira/config.json` exists, and it does not nag the operator to run
`/arkira-init`. It references no app-only or static-web-only standard.

## Artifact contract

Reads operator free text. Writes `docs/product-idea.md`. Consumed by `validate`
and the design pass. See `docs/document-contract.md`.

## Workflow

### Step 1 - Mine

Ask for the operator's business, expertise, unfair advantages, and the customers
they already reach. Summarize that context in a short block. This becomes the
Operator input section.

### Step 2 - Synthesize

Produce three to five distinct candidate directions. Each is one paragraph: the
problem, who has it, and the wedge. Keep them genuinely different, not variations
of one idea.

### Step 3 - Score

Score every candidate on the five-axis card, one (weak) to five (strong), each
with a one-line justification:

- Pain. How acute is the problem for the person who has it.
- Reach. How many people or accounts have it.
- Willingness to pay. How ready the buyer is to pay to solve it.
- Founder edge. How well the operator's expertise, assets, and audience fit.
- Feasibility. How buildable a first version is by a small team.

### Step 4 - Select

Recommend the winner and state why in terms of its scores. The operator confirms
or overrides. Do not invent a market-size or revenue number to justify a choice.
If a number is used, it carries a source.

### Step 5 - Sharpen

Expand the winner into the selected direction: problem, target customer, the
wedge, why now, why this operator.

### Step 6 - Write

Write `docs/product-idea.md` in the structure below.

## Output: docs/product-idea.md

```markdown
# Product Idea: <working title>

## Operator input

<three to six lines summarizing the mined business, expertise, and reachable customers>

## Candidates

<written once, never rewritten by any later skill>

### C1. <name>

<one paragraph: problem, who has it, the wedge>

| Axis | Score | Justification |
|------|-------|---------------|
| Pain | n | ... |
| Reach | n | ... |
| Willingness to pay | n | ... |
| Founder edge | n | ... |
| Feasibility | n | ... |
| Total | n | |

### C2. <name>

<same shape, three to five candidates total>

## Selected direction

<the sharpened winner: problem, target customer, the wedge, why now, why this operator>
```

## Resumability

Re-read `docs/product-idea.md` if it exists. When a `## Candidates` section is
already present, skip synthesis and resume at selection or sharpening. The
`## Candidates` section is written once and never rewritten. This is the resume
contract. No separate state file is used.

## Common Mistakes

- Rewriting the `## Candidates` section. It is written once. `validate` and any
  later run preserve it verbatim.
- Producing near-duplicate candidates. Three genuinely different directions beat
  five variations of one.
- Stating a market-size or revenue figure as fact with no source.
- Gating the skill behind `/arkira-init`. It runs before a repo exists.
