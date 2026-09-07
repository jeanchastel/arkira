# Mobile Compliance Standard

Status: canonical. Synced to product repos via `/arkira-sync`.

## Purpose

Require every Arkira-governed app to be fully usable on phones and tablets. Mobile
is a release gate, not a follow-up.

## Scope

Applies to all responsive-web Arkira apps. Native iOS and Android apps are
governed by `mobile/native-app-standard.md`.

## Switch

`mobile_compliance` in `ai-engineering/bootstrap/switches.json`. Default on.

## Standards References

- WCAG 2.2: 1.4.10 Reflow, 1.4.4 Resize Text, 2.5.5 Target Size (Enhanced),
  2.5.8 Target Size (Minimum)
- Apple Human Interface Guidelines (44pt targets)
- Material Design (48dp targets)
- Theme tokens: `theme/theme-standard.md` (`--target-min`, `--breakpoint-*`,
  safe-area utility)

## Rule

Every app must be fully usable on phones and tablets, portrait and landscape. A
core user flow that cannot be completed on a phone is a release blocker.

## Requirements

### Layout and reflow

- Mobile-first. Default styles target mobile; enhance upward with breakpoints.
- Content reflows at 320px CSS width with no horizontal scroll and no loss of
  function (WCAG 1.4.10).
- Tablet is a first-class layout in portrait and landscape, not a stretched phone.
- Use container queries for component-level responsiveness; use the theme
  breakpoint tokens for page layout.

### Touch and input

- Primary interactive targets meet the 44px floor (`--target-min`; Apple HIG and
  WCAG 2.5.5 enhanced).
- 24px is the absolute minimum for dense inline controls, with adequate spacing
  (WCAG 2.5.8 AA).
- No hover-only interactions; touch has no hover. Provide a tap-equivalent.
- Use correct input types so the right mobile keyboard appears.
- Focus is always visible.

### Viewport and safe areas

- Viewport meta uses `width=device-width` and `viewport-fit=cover`.
- Never disable zoom. `user-scalable=no` and `maximum-scale=1` are violations.
- Respect `env(safe-area-inset-*)` via the theme safe-area utility.

### Legibility and zoom

- Text resizes to 200% without loss of content or function (WCAG 1.4.4).
- No fixed tiny type for body content.

### Performance

- Meet a mobile performance budget (sensible LCP and CLS targets); phones run on
  slower networks and devices.

## Do Not

- ship a layout that horizontal-scrolls or breaks at 320px
- disable pinch-to-zoom
- gate critical actions behind hover
- use sub-floor touch targets
- treat tablet as a stretched phone
- assume desktop-only interactions work on touch

## Testing Matrix

Verify on phone and tablet, an iOS and an Android engine, portrait and landscape:

- 320px reflow: no horizontal scroll, all functions reachable
- target size: primary targets meet 44px, dense controls at least 24px with spacing
- zoom: 200% text resize works; pinch-zoom not blocked
- safe areas: content clears notches and home indicators
- a mobile Lighthouse or equivalent pass within the performance budget

## Pre-Ship Checklist

- core flows complete on a phone
- reflows at 320px, no horizontal scroll
- tablet layout verified, portrait and landscape
- primary targets meet the 44px floor
- zoom enabled; text resizes to 200%
- safe-area insets respected
- no hover-only critical actions
- mobile performance budget met

## Failure Conditions

Use the canonical P0 to P3 scale from the Severity Classes block in `ai-engineering/root/AGENTS.md`; these mobile conditions refine that scale for form-factor and accessibility failures.

Classify as `P0 Critical`:

- a core user flow cannot be completed on a phone
- horizontal scroll or broken layout at 320px
- zoom disabled

Classify as `P1 High`:

- primary touch targets below the 44px floor
- no tablet layout
- hover-only critical actions
- text that does not resize to 200%
- mobile performance budget missed by a wide margin

## Final Standard

Desktop is one form factor, not the default. An app that is not usable on a phone
and a tablet is not done.
