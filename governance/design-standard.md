# Design Standard

The harness-level UI baseline. It names the external standard each UI surface is designed,
built, and reviewed against. A product's own visual system lives in its `DESIGN.md`, which
points here (see the `design-system` skill, section 8 of the schema).

Findings against this baseline are advisory. A deviation is reported. It never fails a gate or
blocks a merge on that basis alone. Existing blocking rules elsewhere, for example the
accessibility classification in `mobile/native-app-standard.md`, stay as they are.

## Baseline

| Surface | Baseline |
|---|---|
| All UI | [WCAG 2.2](https://www.w3.org/TR/WCAG22/) AA, applied to native apps as well as web |
| macOS | [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines), macOS sections, including [Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) guidance |
| iOS and iPadOS | Apple Human Interface Guidelines, iOS and iPadOS sections, including Liquid Glass guidance; [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) |
| Android | [Material 3](https://m3.material.io/) and [Material 3 Adaptive](https://developer.android.com/develop/ui/compose/layouts/adaptive) (window size classes); [core app quality](https://developer.android.com/docs/quality-guidelines/core-app-quality) and [large screen app quality](https://developer.android.com/docs/quality-guidelines/large-screen-app-quality) guidelines; [Google Play policy](https://play.google/developer-content-policy/) |
| Windows | [Windows app design guidelines](https://learn.microsoft.com/windows/apps/design) on Microsoft Learn, built on WinUI and the Fluent design language; [Microsoft Store policies](https://learn.microsoft.com/windows/apps/publish/store-policies) |
| Web | [WAI-ARIA Authoring Practices Guide](https://www.w3.org/WAI/ARIA/apg/); [Vercel Web Interface Guidelines](https://vercel.com/design/guidelines); [Core Web Vitals](https://web.dev/articles/defining-core-web-vitals-thresholds) "good" thresholds at the 75th percentile (LCP 2.5 s, INP 200 ms, CLS 0.1) |

Light-touch rows. Each names the HIG section and the main interaction model, with no extra
checks. A row becomes a full row when a product first targets that platform.

| Surface | Baseline |
|---|---|
| watchOS | Apple HIG, watchOS sections: glanceable, short sessions, Digital Crown input |
| tvOS | Apple HIG, tvOS sections: focus-driven navigation with the remote, viewed from a distance |
| visionOS | Apple HIG, visionOS sections: eye and hand input, spatial layout, comfort |

Platform notes:

- Liquid Glass: system components adopt it automatically, and Apple advises using it sparingly in
  custom controls. Prefer system bars, sheets, and controls. See
  [what's new](https://developer.apple.com/design/whats-new).
- Windows: [Fluent 2](https://fluent2.microsoft.design/) mainly documents web and React
  components. For native Windows apps, the Microsoft Learn guidelines are the source.
- Android: core app quality makes 48dp touch targets a quality check, and Google's
  [accessibility help](https://support.google.com/accessibility/android/answer/7101858) adds at
  least 8dp spacing between targets.
- Vercel Web Interface Guidelines ([source](https://github.com/vercel-labs/web-interface-guidelines))
  are a craft checklist. They rank below WCAG and the house floors.

## Compliance note

This is a compliance reference, not a design baseline, and not legal advice. The European
Accessibility Act has applied since 28 June 2025. Its harmonised standard is EN 301 549; version
[4.1.1](https://www.deque.com/blog/en-301-549-v4-1-1-is-final-what-changed-what-it-means-and-what-you-should-do/)
aligns with WCAG 2.2 AA and covers native apps (see also the
[NDA notice](https://nda.ie/news/en301549-published)). EN 301 549 has requirements beyond WCAG,
for example user preferences, so WCAG 2.2 AA alone does not prove EAA conformance.

Watched, not adopted: [WCAG 3](https://www.w3.org/WAI/WCAG3) is a Working Draft
([status](https://www.w3.org/WAI/news/2026-03-03/wcag3)). WCAG 2 stays in force. This standard
does not adopt WCAG 3 until W3C publishes it as a Recommendation.

## Rules

1. Native platform conventions win over house style on that platform. A shared web codebase
   rendered in a native shell follows the native platform's conventions for navigation, controls,
   and gestures.
2. Where two baselines disagree (for example 44pt Apple targets and 48dp Material targets), the
   platform's own baseline applies on that platform, and the larger value applies to shared web.
   WCAG and the house floors in `theme/theme-standard.md` (for example the 44px target floor) are
   never relaxed by a craft checklist.
3. The product's `DESIGN.md` records any intentional deviation with a one-line reason. A recorded
   deviation is not reported again.
4. This standard links to each external source and does not restate it. It lists only the checks
   reviewers most often miss.

## Often missed

The WCAG 2.2 additions at level A and AA:

- 2.4.11 Focus Not Obscured (Minimum): sticky headers, banners, and sheets do not hide the
  focused element.
- 2.5.7 Dragging Movements: every drag has a single-pointer alternative.
- 2.5.8 Target Size (Minimum): 24 by 24 CSS px, or enough spacing. The house floor is higher.
- 3.2.6 Consistent Help: help and contact links appear in the same relative place on each page.
- 3.3.7 Redundant Entry: a multi-step flow does not ask again for data already entered.
- 3.3.8 Accessible Authentication (Minimum): sign-in needs no memory or puzzle test; allow paste
  and password managers.

Also: reduced motion honored, visible focus everywhere, and loading, empty, and error states
designed rather than left blank.

## Tooling

For web UI, review runs the `web-design-guidelines` skill when it is installed. The harness does
not vendor or distribute it. A missing skill is not a failure.
