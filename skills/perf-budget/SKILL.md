---
name: perf-budget
description: "Check a static brochure site against the static-web performance budget. Lighthouse mobile 90+, page weight under 1MB, WebP images with srcset, self-hosted fonts with font-display swap, no render-blocking third-party scripts. Two modes: local (walks the repo) and live (runs Lighthouse against a URL). Use before launch, after adding assets, or as a regression check."
paths:
  - "**/*.html"
  - "**/*.css"
  - "**/*.js"
  - "assets/**"
origin: STATIC-WEB
---

# Performance Budget Check

Enforce the static-web performance budget. Two modes: local static analysis of the repo, or live Lighthouse against a deployed URL.

## Profile gate

For repos with `profile: static-web` in `.arkira/config.json`. App repos should use `production-audit` (which has its own performance lane) plus Vercel Speed Insights / Core Web Vitals dashboards. If `.arkira/config.json` is missing, run `/arkira-init-web` to mark the repo static-web.

## When to Use

- Before launch.
- After dropping in new hero imagery or third-party scripts.
- Monthly as a regression check on the live site.
- When the user says "check performance", "is this fast", "audit Lighthouse".

For UI breakage at breakpoints, use responsive. For markup quality, use html-audit. This skill cares about weight, format, and what the browser does on first paint.

## How It Works

When a deploy-prep shared working set is present, evaluate the performance lens against that set and do not re-enumerate or re-read files. Standalone invocation still self-scans `**/*.html`, `**/*.css`, `**/*.js`, and `assets/**`.

### Budget

- Lighthouse mobile performance: 90 or higher. Below blocks ship.
- First contentful paint under 2 seconds on simulated 4G.
- Home page total weight under 1MB, excluding optional below-fold hero video.
- All raster images: WebP, with `srcset`, lazy-loaded below the fold.
- All fonts: self-hosted, `font-display: swap`, subset where practical.
- No render-blocking third-party scripts in `<head>`. Analytics is the typical offender; load it `defer` or `async`.

### Local mode

Walk the repo. Per page (each `.html`):

1. Sum the weight of every asset referenced directly or transitively (images, fonts, CSS, JS).
2. Flag raster images larger than 200KB or in PNG/JPG when WebP would serve.
3. Flag `<img>` without `srcset` or without `loading="lazy"` where below the fold.
4. Flag Google Fonts and other external font CDNs.
5. Flag external scripts in `<head>` without `defer` or `async`.
6. Flag inline `<style>` or `<script>` blocks larger than 4KB (they should probably be external).

### Live mode

If given a URL, run Lighthouse mobile and report Core Web Vitals (LCP, INP, CLS) against the budget. If Lighthouse is unavailable, fall back to local mode and note the missing live data.

### Output

Local:

```
Page: index.html
  Weight:        842 KB              PASS  (<1MB)
  Images:        7 (3 WebP, 4 PNG)   FAIL  - convert PNG to WebP
  Lazy load:     5/7 below-fold      FAIL  - add loading="lazy" to 2
  Fonts:         self-hosted, swap   PASS
  Render block:  1 external script   FAIL  - add defer
```

Live:

```
Lighthouse mobile: 88 / 100  FAIL (target 90)
  LCP: 2.4s  budget: 2.5s  PASS
  CLS: 0.12  budget: 0.10  FAIL
  INP: 180ms budget: 200ms PASS
```

End with: `Budget met` or `Budget missed: <count> items`.

## Cross-references

- `static-web/static-web-standard.md`, section "Performance budget".
- responsive for srcset behavior across breakpoints.
- deploy-prep, which aggregates this verdict into the launch gate.
