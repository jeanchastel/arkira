---
name: a11y-audit-aa
description: WCAG 2.1 AA accessibility audit for static brochure sites. Reports prioritized findings (blockers, issues, polish) with WCAG criteria, locations, and suggested fixes. Covers contrast, focus, keyboard, touch targets, form labels, reduced motion. Use before launch, after layout or color changes, or when the user says "audit a11y", "is this accessible", "check WCAG".
paths:
  - "**/*.html"
  - "**/*.css"
origin: STATIC-WEB
---

# Accessibility Audit (WCAG 2.1 AA)

Audit a static brochure site against WCAG 2.1 AA. Output is a prioritized report meant to inform the pre-ship gate.

## Profile gate

For repos with `profile: static-web` in `.arkira/config.json`. App repos (Next.js, Vercel, mobile) should use the `accessibility` skill in the ECC plugin, which covers component-level WCAG checks and framework idioms. If `.arkira/config.json` is missing, run `/arkira-init-web` to mark the repo static-web.

## When to Use

- Before launch.
- After a layout, color, or component change.
- When the user says "audit a11y", "is this accessible", "check WCAG".

For markup-level structural defects only (heading order, landmarks, valid `alt` attribute presence), html-audit is lighter and faster. For layout breakage at breakpoints, use responsive. This skill cares about the user experience for people relying on assistive tech, keyboards, or non-default settings.

## How It Works

When a deploy-prep shared working set is present, evaluate the accessibility lens against that set and do not re-enumerate or re-read files. Standalone invocation still self-scans `**/*.html` and `**/*.css`.

### Principles

1. AA is the floor, not the goal.
2. Native HTML elements are accessible by default. Custom widgets must rebuild what native gives you, which is rarely worth it.
3. Visual focus matters as much as logical focus. If you cannot see where the keyboard is, the site is unusable for keyboard users.
4. Contrast is calculated against the resolved color, not the variable name. Audit with the tokens layer applied.

### Checks

#### Perceivable

- Color contrast for body text: 4.5:1 minimum. Compute from CSS variables resolved against the surface the text sits on.
- Color contrast for large text (24px+, or 18.66px+ bold): 3:1 minimum.
- Color contrast for UI components and graphical objects: 3:1.
- No color-only signal (e.g., a link distinguished only by color, with no underline or icon).
- Text resizes to 200% without horizontal scroll.
- Images convey their content through `alt` or surrounding text.

#### Operable

- Every interactive element is keyboard reachable in a logical tab order.
- A visible focus state exists for every interactive element. Style `:focus-visible` distinctly from the resting state.
- Touch targets are at least 44x44 px for primary actions (Apple HIG, WCAG 2.5.5 enhanced). 24x24 minimum for dense inline controls (WCAG 2.5.8 AA).
- No keyboard traps.
- No positive `tabindex` values.
- Skip-to-content link present and visible on focus when the site has a long nav.

#### Understandable

- `<html lang="...">` set.
- Page title set and meaningful.
- Form labels are programmatically associated with inputs.
- Form errors are programmatically linked (via `aria-describedby` or visible inline text adjacent to the field).
- Placeholders are not used as labels.

#### Robust

- Valid HTML (no duplicate IDs, no unclosed tags).
- ARIA used only when native HTML cannot achieve the same effect.
- Custom widgets implement the WAI-ARIA Authoring Practices role and state correctly.

#### Motion and preferences

- `@media (prefers-reduced-motion: reduce)` honored. Any motion that runs on load or hover is suppressed under this query.

### Output

For each page or component scanned, group findings:

```
BLOCKER  - WCAG AA failure, must fix before launch
ISSUE    - WCAG AA risk, should fix before launch
POLISH   - best practice, worth fixing
```

Each finding includes location (file:line or selector), WCAG criterion (e.g., 1.4.3 Contrast Minimum), description, and a specific fix.

End with: `N blockers, M issues, P polish across K pages. AA target: <pass | conditional | fail>.`

## Cross-references

- `static-web/static-web-standard.md`, section "Accessibility minimum".
- html-audit for markup-level defects.
- responsive for layout integrity at breakpoints.
