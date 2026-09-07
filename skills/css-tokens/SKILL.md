---
name: css-tokens
description: Migrate hardcoded color, spacing, and typography values in static-site CSS to CSS custom properties aligned with the static-web token layer and the entity brand kit. Use when porting CSS from a website-builder export, normalizing a site against the brand kit, or introducing dark or per-brand mode. For Tailwind-based projects, use the design-system skill instead.
paths:
  - "**/*.css"
origin: STATIC-WEB
---

# CSS Tokens Refactor

Pull hardcoded literals out of stylesheets and replace them with CSS custom properties layered against the brand kit. Creates a `styles/tokens.css` if one does not exist.

## Profile gate

For repos with `profile: static-web` in `.arkira/config.json`. For Tailwind- or component-system-based projects, use `design-system` instead, which handles `@theme` tokens, shadcn semantic tokens, and Tailwind config. If `.arkira/config.json` is missing, run `/arkira-init-web` to mark the repo static-web.

## When to Use

- After pasting CSS from a Hostinger, Zyro, Wix, or Squarespace export.
- When aligning a static site to the entity brand kit.
- When introducing dark mode or per-brand overrides.
- When the user says "tokenize this CSS", "align to the brand kit", "refactor to variables".

For app code with Tailwind, use the existing design-system skill instead. This skill targets plain CSS for static brochure sites.

## How It Works

### Principles

1. Tokens are the source of truth. Components reference semantic tokens; semantic tokens reference primitives.
2. Per-entity brand changes touch primitives only, under a `[data-brand="..."]` selector.
3. Dark mode overrides semantic tokens only.
4. One-off values are not always tokens. Tokenize values that repeat or carry meaning; leave true one-offs alone.

### Procedure

1. Scan the styles directory. Count unique values for color, font-family, font-size, line-height, spacing (margin/padding), border-radius, shadow, breakpoint.
2. Bucket repeats. Any value appearing 3 or more times is a token candidate. Single-use values are flagged but only tokenized if they carry meaning (e.g., a brand accent used in one CTA today).
3. Propose token names using the static-web semantic naming below.
4. Create or update `styles/tokens.css` with primitives in `:root`, per-brand overrides under `[data-brand="..."]`, dark overrides under `:root.dark` or `@media (prefers-color-scheme: dark)`.
5. Rewrite stylesheets to consume `var(--token)` instead of literals.
6. Emit a diff report: tokens introduced, literals replaced, files modified, leftover literals.

### Token taxonomy (static-web defaults)

Primitives (defined in `:root` and per-brand selectors):

- Colors: scale per the brand kit. OKLCH where the brand kit defines it; hex otherwise.
- Spacing: `--space-1` (4px) through `--space-12` (96px), or as the entity brand kit defines.
- Typography: `--font-display`, `--font-body`, scale `--text-sm` / `--text-base` / `--text-lg` / `--text-xl` / `--text-2xl` / `--text-display`.
- Radii: `--radius-sm` / `--radius-md` / `--radius-lg` / `--radius-full`.
- Shadows: `--shadow-1` / `--shadow-2` / `--shadow-3`.

Semantic (defined once, consumed by components):

- `--color-bg`, `--color-fg`, `--color-accent`, `--color-muted`, `--color-link`, `--color-link-hover`, `--color-border`.

Components reference semantic tokens only. Components do not branch on brand or mode; brand and mode change tokens, not components.

### Output

A summary like:

```
Tokens introduced:   12 (8 color, 4 typography)
Literals replaced:   147
Files modified:      3 (styles/main.css, styles/components.css, styles/tokens.css)
Leftover literals:   6 (see report)
```

Then a one-screen report with: tokens added (with values), unrefactored literals with file:line and reason, and any conflicts (the same value used semantically differently in different places).

## Cross-references

- `static-web/static-web-standard.md`, section "Brand kit integration".
- `theme/theme-standard.md` for the full three-layer model (Tailwind v4 + shadcn) used in app code.
- design-system skill for the Tailwind-based equivalent.
