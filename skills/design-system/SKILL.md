---
name: design-system
description: Generate or audit a design system from Tailwind or CSS tokens, extract and check design tokens, run an AI-slop visual-consistency audit, and review styling-only PRs. Use for token and styling-system work, not general UX critique; defer UX critique to the design plugin.
paths:
  - "**/*.css"
  - "tailwind.config.*"
  - "**/*.{tsx,jsx}"
origin: ECC
reads: [DESIGN.md]
writes: [DESIGN.md]
---

# Design System: Generate & Audit Visual Systems

## When to Use

- Starting a new project that needs a design system
- Auditing an existing codebase for visual consistency
- Before a redesign: understand what you have
- When the UI looks "off" but you can't pinpoint why
- Reviewing PRs that touch styling

## Artifact contract

Reads `DESIGN.md` in audit mode or the project codebase in generate mode. Writes
`DESIGN.md` against the nine-section schema (`references/design-md-schema.md`).
Consumed by review-pass and the audit workflows. See `docs/document-contract.md`.

## How It Works

### Mode 1: Generate Design System

Analyzes your codebase and generates a cohesive design system:

```text
1. Scan CSS/Tailwind/styled-components for existing patterns
2. Extract: colors, typography, spacing, border-radius, shadows, breakpoints
3. Research 3 competitor sites for inspiration (via browser MCP)
4. Propose a design token set (JSON + CSS custom properties)
5. Generate DESIGN.md against the 9-section schema, with rationale per decision
6. Create an interactive HTML preview page (self-contained, no deps)
```

Output: `DESIGN.md` + `design-tokens.json` + `design-preview.html`

`DESIGN.md` follows the nine-section schema in `references/design-md-schema.md`
(Brand & Personality, Color System, Typography, Spacing & Layout, Elevation &
Surfaces, Motion & Interaction, Components, Accessibility, Implementation &
Tokens). Emit every section in order; never leave a placeholder: if a decision
is unmade, state the default chosen and why. The schema's closing contract holds:
a brand or theme change is a token change in section 9, not a component edit.

Image intake (optional source). Instead of or alongside the codebase scan in step
1, derive tokens from a provided image: a screenshot, mockup, or exported artboard.
Use vision to read the color palette, the typography hierarchy, the spacing scale,
and the radius and shadow treatment, then feed the same token set and DESIGN.md
schema as above. This needs a vision-capable model. Extraction is approximate, so
confirm the derived tokens with the operator before writing them. The Figma-URL
path is deferred and out of scope here, because it needs external Figma access.

### Mode 2: Visual Audit

Scores your UI across 10 dimensions (0-10 each):

```text
1. Color consistency: are you using your palette or random hex values?
2. Typography hierarchy: clear h1 > h2 > h3 > body > caption?
3. Spacing rhythm: consistent scale (4px/8px/16px) or arbitrary?
4. Component consistency: do similar elements look similar?
5. Responsive behavior: fluid or broken at breakpoints?
6. Dark mode: complete or half-done?
7. Animation: purposeful or gratuitous?
8. Accessibility: contrast ratios, focus states, touch targets
9. Information density: cluttered or clean?
10. Polish: hover states, transitions, loading states, empty states
```

Each dimension gets a score, specific examples, and a fix with exact file:line.
Map findings back to the `references/design-md-schema.md` section they belong to
(e.g. color drift → section 2, arbitrary spacing → section 4) so an audit reads
as gaps against the documented system, not a loose list.

### Mode 3: AI Slop Detection

Identifies generic AI-generated design patterns:

```text
- Gratuitous gradients on everything
- Purple-to-blue defaults
- "Glass morphism" cards with no purpose
- Rounded corners on things that shouldn't be rounded
- Excessive animations on scroll
- Generic hero with centered text over stock gradient
- Sans-serif font stack with no personality
```

## Examples

**Generate for a SaaS app:**

```text
/design-system generate --style minimal --palette earth-tones
```

**Audit existing UI:**

```text
/design-system audit --url http://localhost:3000 --pages / /pricing /docs
```

**Check for AI slop:**

```text
/design-system slop-check
```
