---
name: deploy-prep
description: Pre-flight gate before pushing a static brochure site to FTP or Netlify. Composes html-audit, a11y-audit-aa, perf-budget, and responsive; adds deploy-specific checks (sitemap, robots, headers file, OG/canonical, no committed secrets, 404 present, no TODO/Lorem). Emits a single verdict (OK to deploy or BLOCK DEPLOY) with a punch list. Use right before deploy.sh or a Netlify push, or when the user says "ready to deploy", "pre-flight", "launch check".
origin: STATIC-WEB
reads: []
writes: [audit-report]
---

# Deploy Prep

The launch gate for a static brochure site. Composes the other static-web audit skills, adds deploy-specific checks, and emits a single go/no-go verdict.

## Profile gate

For repos with `profile: static-web` in `.arkira/config.json`. App repos should gate releases with `production-audit` plus framework-native pre-deploy steps (Vercel preview env validation, smoke tests, e2e). If `.arkira/config.json` is missing, run `/arkira-init-web` to mark the repo static-web.

## When to Use

- Right before `./deploy/deploy.sh` (FTP) or a Netlify push.
- After a major change, to confirm the site is still launch-ready.
- When the user says "ready to deploy", "pre-flight", "launch check".

## Artifact contract

Reads the composed static-web audit outputs (html-audit, a11y-audit-aa,
perf-budget, responsive). Writes a single deploy verdict to `reports/` or
`reports/`. Consumed by the operator and remediation-pass. See
`docs/document-contract.md`.

## How It Works

### Composition

Scan once before running any lens. Enumerate the union of `**/*.html`, `**/*.css`, `**/*.js`, and `assets/**` into one shared working set, read each matched file once, and record an inventory grouped by type with path and size. The audit lenses consume this shared working set and inventory instead of enumerating or reading the same files again.

Run each of the other static-web audits (or read its cached report if recent) and capture the highest severity:

- html-audit
- a11y-audit-aa
- perf-budget
- responsive

Any BLOCKER from any of the above blocks the deploy. ISSUE counts surface in the report but do not block by default. The user can override and ship with open ISSUEs; the override is recorded.

### Additional deploy-specific checks

1. `sitemap.xml` exists, lists every public page, URLs use the production domain.
2. `robots.txt` exists, references the sitemap, allows crawling.
3. Security headers file present: `.htaccess` for cPanel/FTP hosts, `_headers` for Netlify.
4. Open Graph, Twitter, and canonical tags present on every page.
5. `404.html` exists and is on-brand.
6. No `.env` committed to git. `deploy/.env.example` does not contain real values.
7. No `TODO`, `FIXME`, "Lorem ipsum", or builder placeholder copy in source.
8. Contact form: ask the user to confirm a recent end-to-end test was made and the email arrived. This is the one check that cannot be automated reliably.
9. SSL active on the production domain (verify with a single HTTPS fetch).
10. The `data-brand` attribute on `<body>` matches the entity expected per `.arkira/config.json`.

### Output

A single one-screen report:

```
Deploy gate for <repo> -> <host>

Composed audits:
  html-audit:        PASS
  a11y-audit-aa:               PASS (3 polish open)
  perf-budget:    ISSUE (1 image too large)
  responsive:            PASS

Deploy-specific:
  sitemap.xml:                 PASS
  robots.txt:                  PASS
  security headers:            PASS  (.htaccess)
  OG/Twitter/canonical:        PASS
  404.html:                    PASS
  no committed secrets:        PASS
  no placeholder copy:         PASS
  contact form smoke test:     USER CONFIRMS REQUIRED
  SSL on production:           PASS
  data-brand matches:          PASS

Verdict: BLOCK DEPLOY (1 issue)
  Fix: assets/images/hero.jpg is 1.4MB. Convert to WebP and add srcset.
```

### Override behavior

The user can override BLOCK DEPLOY only by explicit confirmation in chat. The override is recorded in `.arkira/deploy-overrides.log` with timestamp, the failing item, and the user's reason so future audits can see what was waived and when.

### Non-Technical Walkthrough (optional)

Emit this only when the operator asks for a plain-language walkthrough. It never
replaces the verdict above. It restates it for a non-technical founder.

Render the verdict as a short checklist. For each item, mark who acts, define any
technical term inline, and end with what success looks like:

- Who acts: you, the agent, or both together.
- An inline definition of any term (for example, "canonical tag is the one URL you
  tell search engines is the real page").
- A "you will know it worked when" line.

Preserve the P0 to P3 severity of each item. A BLOCK DEPLOY item stays a blocker in
plain language, not a suggestion.

## Cross-references

- `static-web/static-web-standard.md`, section "Pre-ship checklist".
- The audits it composes: html-audit, a11y-audit-aa, perf-budget, responsive.
- css-tokens is related but not composed (run it when migrating CSS, not at deploy time).
