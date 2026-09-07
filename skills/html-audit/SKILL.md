---
name: html-audit
description: Static-site HTML audit covering heading hierarchy, landmark elements, alt text coverage, form label association, link and title quality. Use when checking markup before launch, after pasting in content from a builder export, or whenever the user says "audit my HTML", "is this semantic", "lint my markup". For experiential accessibility (contrast, focus, keyboard), pair with a11y-audit-aa.
paths:
  - "**/*.html"
origin: STATIC-WEB
---

# HTML Semantics Audit

Lint static HTML markup for structural correctness. The kind of defects that break assistive tech, SEO, and downstream tooling consistency without necessarily breaking layout.

## Profile gate

For repos with `profile: static-web` in `.arkira/config.json`. If the repo profile is `app` (or any non-static-web value), this skill is the wrong tool. App repos should use `design-system` for component markup hygiene, `production-audit` for broader launch readiness, and their framework's own linting (Next.js linting, `@next/eslint-plugin-next`, etc.). If `.arkira/config.json` is missing, run `/arkira-init-web` to mark the repo static-web.

## When to Use

- Before launch.
- After porting content from a builder export (Hostinger, Wix, Squarespace).
- After templating changes that touch landmarks or headings.
- When the user asks "audit my HTML", "is this semantic", "lint my markup".

For user-impact accessibility checks (contrast, focus state, keyboard, touch targets, motion), use a11y-audit-aa. The two overlap on alt text and label association. This skill names the markup defect; that one names the experience impact.

## How It Works

When a deploy-prep shared working set is present, evaluate the HTML lens against that set and do not re-enumerate or re-read files. Standalone invocation still self-scans `**/*.html`.

### Principles

1. Each page is a tree, not a flat soup. Landmark elements anchor it.
2. One H1 per page. Headings descend in order with no skipped levels.
3. Decorative imagery is invisible to assistive tech (`alt=""`). Content imagery is described.
4. Every form input has a programmatic label.
5. Link and button text is meaningful out of context.

### Checks

#### Document

- `<html lang="...">` set and non-empty.
- `<title>` present and unique per page.
- `<meta name="description">` present per page.
- `<meta name="viewport" content="width=device-width, initial-scale=1">`.
- Charset declared in the first 1024 bytes.

#### Landmarks

- `<header>` at the top of body for site header.
- `<nav>` wrapping primary navigation.
- `<main>` wrapping page-specific content, exactly one per page.
- `<footer>` at the bottom of body.
- `<aside>` and `<section>` used semantically when present.

#### Headings

- Exactly one `<h1>` per page.
- No skipped levels (h1, then h2 before h3, etc.).
- No purely visual heading uses (e.g., `<h2>` styled smaller than the surrounding body).

#### Images

- Every `<img>` has an `alt` attribute (even empty).
- Content images have descriptive `alt` (not the filename).
- Decorative images use `alt=""`.
- Logo `<img>` includes the brand name in `alt` when it serves as the site-name link.

#### Links and buttons

- Link text is meaningful out of context. Flag "click here", "read more", "learn more" without nearby context.
- External links: consider `rel="noopener"` when opening in a new tab.
- Buttons that do not navigate are `<button>`, not `<a>`.

#### Forms

- Every `<input>`, `<select>`, `<textarea>` has either an associated `<label for="...">` or wraps inside a `<label>`.
- Required fields have `required` and a visible indicator.
- Placeholders are not used as labels.
- Submit buttons say what they submit ("Send message", not "Submit").

#### Tables

- Data tables have `<th scope="col">` headers and an optional `<caption>`.
- Tables are not used for layout.

### Output

Per file, group findings by severity:

```
BLOCKER  - must fix before launch
ISSUE    - should fix before launch
POLISH   - worth fixing
```

Each finding includes file path, line number, the offending element, the rule violated, and a suggested fix.

End with: `N blockers, M issues, P polish items across K files.`

## Cross-references

- `static-web/static-web-standard.md`, sections "Accessibility minimum" and "SEO baseline".
- a11y-audit-aa for user-impact accessibility checks.
- seo skill for content and meta optimization beyond markup.
