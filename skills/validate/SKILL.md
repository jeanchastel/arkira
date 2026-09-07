---
name: validate
description: Pre-build validation for a product direction. State the single core assumption, rank fatal flaws with distribution and pricing treated as fatal, map current behavior as the real competition, plan the first ten customers by hand, define a two-week behavioral test, and return a strong, weak, or pivot verdict. Writes docs/validation-report.md and sharpens docs/product-idea.md. Use after ideate, before the design pass.
origin: arkira (patterns adapted from buildgreatproducts/builder-os idea-validator, MIT)
reads: [product-idea.md]
writes: [validation-report.md]
---

# Validate

Pressure-test a product direction before any build. Surface the one assumption
that must hold, the flaws that could kill it, the real alternative the customer
uses today, a concrete first-ten-customer plan, and a two-week behavioral test
that would prove or disprove demand.

Patterns adapted from `buildgreatproducts/builder-os` (idea-validator), MIT
licensed. Adapted, not copied.

## When to Use

- After `ideate`, before the design pass.
- On any product direction that has not been market-tested, to decide strong,
  weak, or pivot.

Not for: a direction already validated (go to the design pass). Not for: scoring
candidates (that is `ideate`).

## Profile gate

None. This skill is profile-agnostic. It runs before `/arkira-init` and whether
or not `.arkira/config.json` exists. It does not nag the operator to run
`/arkira-init`. It references no app-only or static-web-only standard.

## Artifact contract

Reads `docs/product-idea.md`. Writes `docs/validation-report.md` and sharpens
`docs/product-idea.md` with the `## Candidates` section preserved verbatim.
Consumed by the design pass. See `docs/document-contract.md`.

## Workflow

### Step 1 - Core assumption

State the single belief that must be true for the product to work. Exactly one
sentence. If more than one belief is load-bearing, name the one that fails first.

### Step 2 - Fatal flaws

Rank the flaws that could kill the product. Distribution and pricing are always
assessed, and each is eligible to be fatal (P0). Each flaw carries a severity
(P0 to P3), why it could be fatal, and the cheapest test that would resolve it.

### Step 3 - Competition as current behavior

Describe what the target customer does today instead of buying this. The real
competition is current behavior, not a list of named competitor products. Name a
product only if the customer already uses it for this job.

### Step 4 - First ten customers

Name ten reachable individuals or specific accounts and how to reach each. Not
market segments. If ten cannot be named, that is itself a distribution finding
for Step 2.

### Step 5 - Two-week behavioral test

Define an observable behavior that would prove demand within two weeks, with a
success threshold. A survey or an opinion poll does not qualify. Prefer a
pre-order, a signed pilot, a deposit, or a completed task over a stated
intention.

### Step 6 - Verdict

Return exactly one of strong, weak, or pivot, with a one-paragraph rationale
grounded in the evidence above.

### Step 7 - Write and sharpen

Write `docs/validation-report.md` in the structure below. Then sharpen
`docs/product-idea.md`: update the `## Selected direction` section with what
validation learned, and preserve the `## Candidates` section verbatim.

## Verdict to severity

The design pass reads the verdict and maps it. The mapping is advisory: the
operator decides whether to proceed.

- pivot maps to P0. The direction likely fails as stated.
- weak maps to P1. Real risk to resolve before production reliance.
- strong maps to no blocker.

## Output: docs/validation-report.md

```markdown
# Validation Report: <working title>

## Core assumption

<one sentence: the single belief that must be true>

## Fatal flaws (ranked)

1. <flaw> (P0 to P3). Why it could be fatal. Cheapest test to resolve it.
2. <distribution and pricing always appear here, each assessed>

## Competition: current behavior

<what the target customer does today instead of buying this>

## First ten customers

1. <named person or account> and how to reach them.
2. <ten total, no segments>

## Two-week behavioral test

<observable behavior that proves demand, with a success threshold>

## Verdict

<strong | weak | pivot>. <one-paragraph rationale grounded in the evidence above>
```

## Common Mistakes

- Listing named competitor products instead of describing what the customer does
  today. Current behavior is the competition.
- First ten customers written as segments ("small law firms") instead of named
  reachable accounts.
- A survey as the behavioral test. Measure a behavior, not an opinion.
- Rewriting the `## Candidates` section in product-idea.md. It is preserved
  verbatim.
- Omitting distribution or pricing from the fatal-flaw ranking. Both are always
  assessed and both can be P0.
