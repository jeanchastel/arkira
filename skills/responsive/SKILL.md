---
name: responsive
description: "Verify a static brochure site is mobile-first across 320, 375, 768, 1024, and 1440 breakpoints, checking horizontal scroll, broken layouts, overflowing images, fixed widths, and missing container queries in static CSS or live Chrome MCP. Use after layout changes, before launch, or for \"is this responsive\" or \"check breakpoints\"."
paths:
  - "**/*.html"
  - "**/*.css"
origin: STATIC-WEB
---

# Responsive Audit

Verify mobile-first layout across the breakpoints the static-web standard expects.

## Profile gate

Use for repos with `profile: static-web`; see `static-web/static-web-standard.md` for the profile gate.

## When to Use

- After a layout change.
- Before launch.
- When the user says "is this responsive", "looks weird on my phone", "check breakpoints".

For accessibility (touch targets, text scaling), use a11y-audit-aa. For asset weight per breakpoint, use perf-budget. This skill cares about layout integrity.

## How It Works

When a deploy-prep shared working set is present, evaluate the responsive lens against that set and do not re-enumerate or re-read files. Standalone invocation still self-scans `**/*.html` and `**/*.css`.

### Breakpoints

Audit at 320, 375, 768, 1024, and 1440 px wide.

- 320: the WCAG reflow floor.
- 375: iPhone width.
- 768: iPad portrait.
- 1024: iPad landscape and small desktop.
- 1440: typical desktop.

### Principles

1. Mobile-first. Unprefixed utilities target mobile; `md:` and `lg:` enhance upward.
2. No fixed pixel widths on layout containers. Use percentages, `max-width`, or container queries.
3. Images and embedded media are `max-width: 100%; height: auto`.
4. No horizontal scroll at any breakpoint.
5. Component-level responsiveness uses container queries. Viewport breakpoints are for page layout.
6. Tablet is a first-class layout, not a stretched phone.

### Static checks

1. `<meta name="viewport">` set correctly.
2. CSS: no `width: <Npx>` on top-level layout containers.
3. CSS: media queries are mobile-first (smallest first, min-width based).
4. CSS: `img { max-width: 100%; height: auto; }` baseline exists or is applied per image.
5. CSS: container queries (`@container`) used for components that adapt to their container.
6. CSS: no overflow-causing patterns (`white-space: nowrap` on body-level elements, oversized `min-width`).

### Live checks (if Chrome MCP is available)

1. Render the URL at each breakpoint.
2. Screenshot each.
3. Check for horizontal scrollbars.
4. Compare layout integrity (no clipped CTAs, no overflowing hero text).
5. Spot-check touch-target spacing at 320 and 375.

### Output

```
Breakpoint 320:  PASS
Breakpoint 375:  PASS
Breakpoint 768:  ISSUE  hero CTA overflows by 12px
Breakpoint 1024: PASS
Breakpoint 1440: PASS

Static findings:
  styles/main.css:42  fixed width 1200px on .container
  styles/main.css:88  media query is desktop-first (max-width)
```

End with: `Responsive at <count>/5 breakpoints.`

## Cross-references

- `static-web/static-web-standard.md`, sections "Project layout" and "Accessibility minimum".
- a11y-audit-aa for touch targets and text scaling.
- perf-budget for srcset and image weight per breakpoint.
