# Third-Party Skills Standard

Decision: P2. Treat third-party skills as supply-chain surface and govern them
like vendored tools before they can affect autonomous agent behavior.

## Trusted Sources

Decision: P1. Adopt third-party skills only from a reputable, identifiable
publisher:

- an official first-party publisher (e.g. Anthropic, Vercel);
- a verified GitHub organization;
- the Trail of Bits curated marketplace `github.com/trailofbits/skills-curated`;
- an established, identifiable maintainer with a review trail.

This is a trust bar, not a fixed allowlist. The protection against a malicious
skill is the adoption gate below (pin, line-by-line review, recorded date),
not the identity of the source. Every adopted source must be recorded in
`VENDORED.md` with the fields the adoption requirements demand.

### Existing sources reconciled

Decision: P1. The following already-vendored sources satisfy the trust
criterion and are recorded in `VENDORED.md`:

- `affaan-m/everything-claude-code` (`ecc`) - established maintainer, MIT, pinned.
- `DietrichGebert/ponytail` - established maintainer, MIT, pinned, hooks reviewed.
- `gitleaks/gitleaks` - local secret scanner, MIT, pinned.
- `vercel-labs/agent-skills` - Vercel first-party, MIT, pinned.

## Adoption Requirements

Decision: P1. Complete all requirements before wiring a third-party skill into
any workflow:

- Pin the exact version, tag, and commit in `VENDORED.md`.
- Read every hook and script line by line before adoption.
- Record the hook and script review date in `VENDORED.md`.
- Never wire an unreviewed marketplace skill into an autonomous flow.

## Review Cadence

Decision: P2. Re-review every adopted third-party skill on the 3-to-6-month
cadence in [Harness Review Standard](../governance/harness-review-standard.md).

Each review confirms:

- the skill remains pinned in `VENDORED.md`;
- the source remains one of the allowed sources in this standard;
- hooks and scripts are unchanged since the last recorded review, or were
  reviewed line by line again before adoption of the change.

## Severity

Decision: P1. Classify third-party skill governance failures by blast radius.

- P1: an unreviewed third-party hook wired into an autonomous flow.
- P2: an unpinned third-party skill.
- P3: an optional candidate listed for later review but not installed.

## Optional Vetted Adds

Decision: P3. These candidates are listed for later consideration and are not
installed:

- `openai-sentry`: production error observability.
- `openai-security-threat-model`: deeper `production-audit` coverage.
- `openai-security-ownership-map`: deeper `production-audit` coverage.
- `skill-extractor`: candidate skill extraction workflow.
- `humanizer`: candidate copy refinement workflow.

## Add, Remove, Swap Conclusion

Decision: P3. Record the third-party skill conclusion without installing or
rewiring anything in this pass.

- Add: Gitleaks as the local explicit-only secret scanner.
- Remove: nothing.
- Swap: retire GitGuardian and its hosted API dependency.
- Context: borrow `context-engineering-kit` patterns into the existing
  `context-discipline` skill rather than running a second context skill. This
  is a conclusion only, not an implementation in this chunk.
