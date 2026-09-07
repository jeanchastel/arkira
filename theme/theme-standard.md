# Theme System Standard

Status: canonical. Synced to product repos via `/arkira-sync`.

## Switch

`design_token_discipline` in `ai-engineering/bootstrap/switches.json`. Default on.

## Three-Layer Model

1. Tokens (source of truth): W3C Design Tokens Format JSON. One base set plus a
   per-brand override set. Tokens reference each other (`{color.brand.500}`) and
   carry `$type` and `$value`. Color scales use OKLCH for perceptually even steps.
2. Pipeline: Style Dictionary compiles the JSON into CSS variables, wrapped into a
   Tailwind v4 `@theme` block.
3. Runtime and components: Tailwind v4 `@theme` exposes the tokens as utilities and
   runtime CSS variables; shadcn/ui semantic tokens (`background`, `foreground`,
   `primary`, `--radius`, ...) map onto them under `:root` and `.dark`. Dark mode
   and brand switching are selector-level token overrides, no rebuild.

## Token Taxonomy

- Primitive scales: color (OKLCH), spacing, radius, typography, shadow, and
  motion. Motion primitives are `duration.fast` (`150ms`), `duration.base`
  (`250ms`), and `duration.slow` (`400ms`) with `$type: "duration"`; and
  `easing.standard` (`[0.4, 0, 0.2, 1]`), `easing.enter`
  (`[0, 0, 0.2, 1]`), and `easing.exit` (`[0.4, 0, 1, 1]`) with
  `$type: "cubicBezier"`.
- Semantic tokens: `background`, `foreground`, `primary`, `secondary`, `muted`,
  `accent`, `destructive`, `border`, `input`, `ring`, `--radius`, and the
  semantic motion pairs `--motion-page` (`duration.slow` + `easing.standard`),
  `--motion-shared` (`duration.base` + `easing.standard`), and
  `--motion-reveal` (`duration.fast` + `easing.enter`).
- System tokens: `--breakpoint-*`, `--target-min`.
- Semantic tokens reference primitives; components consume semantic tokens only.

## Brands and Dark Mode

- One base token set; each entity ships a brand override set that changes primitive
  values only.
- Dark mode overrides semantic tokens under `.dark`.
- Brand switching overrides primitives under a `[data-brand="..."]` selector.
- Components never branch on brand or mode; they read semantic tokens.

## Responsive and Mobile Token Layer

- Breakpoints are tokens (`--breakpoint-*`), rem-based, mobile-first. Unprefixed
  utilities are mobile; `md:` and `lg:` enhance upward.
- Use container queries for component-level responsiveness; reserve viewport
  breakpoints for page layout.
- Touch targets: `--target-min: 44px` is the floor for primary interactive targets
  (Apple HIG, WCAG 2.5.5 enhanced). 24px is the absolute minimum for dense inline
  controls (WCAG 2.5.8 AA). Use the `.target-min` utility.
- Safe areas: the app shell sets `viewport-fit=cover` and uses `env(safe-area-inset-*)`
  via the `.pad-safe` utility so content clears notches and home indicators.
- Tablet is a first-class layout, not a stretched phone.

## Motion Token Layer

- Components and view-transition CSS consume the semantic `--motion-*` pairs.
  Raw millisecond values and cubic-bezier curves do not belong in component or
  transition styles.
- Under `@media (prefers-reduced-motion: reduce)`, override the semantic motion
  durations to `0ms`. Keep this selector-level override in the token pipeline,
  matching the dark-mode override pattern.
- This is the token home for the reduced-motion requirement already governed by
  `skills/a11y-audit-aa/SKILL.md` and
  `static-web/static-web-standard.md`; it does not duplicate that requirement.

## Token-Only Styling

Do:

- consume semantic tokens for all themed values
- change a brand or mode by changing tokens, not components
- keep OKLCH color scales

Do not:

- use raw hex or named colors for themed values
- hardcode Tailwind literals for themed values
- branch component logic on brand or mode
- duplicate token files per mode or brand when an override selector will do

## Pre-Ship Checklist

- tokens compile cleanly to CSS
- light and dark both render from the same semantic tokens
- at least one brand override verified by selector switch, no component change
- primary interactive targets meet `--target-min`
- layout reflows at 320px with no horizontal scroll
- safe-area insets respected on a notched device
- motion values come from semantic motion tokens
- reduced-motion override verified
- no raw hex or hardcoded themed literals in components
