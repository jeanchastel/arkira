# Static Web Standard

Status: canonical. Synced to product repos via `/arkira-sync`.

## When to use

Use this standard when the deliverable is a static HTML/CSS marketing or brochure site with no application surface: no build pipeline beyond optional asset optimization, no database, no server-side auth, no runtime APIs. Examples: company sites, landing pages, event microsites, portfolio sites.

For application work (Next.js + Supabase + Vercel, native mobile, dashboards with backed-in state), use the existing standards (`THEME`, `VERCEL`, `SUPABASE`, `MOBILE`, `SECURITY`). Do not pull `STATIC-WEB` into app repos. Init those with `/arkira-init`.

Decision rule: if the site is `index.html` + assets and an FTP push or static deploy gets it live, use this standard. If the site requires `npm install`, an environment with secrets at runtime, or a database, it is not in scope here.

## Switch

`static_web_baseline` in `static-web/switches.json`. Default on once `/arkira-init-web` has been run in the repo. App-oriented switches stay off in static-web repos.

## Project layout

Canonical layout. `/arkira-init-web` produces it.

```
<repo>/
  AGENTS.md             Shared project brief and profile for every agent
  CLAUDE.md             Exact pointer overlay to AGENTS.md
  CODEX.md              Exact pointer overlay to AGENTS.md
  README.md             Local preview and deploy notes
  .gitignore            Excludes .DS_Store, .env, deploy/.env, node_modules
  .arkira/config.json   profile = "static-web", decisions recorded

  index.html            Entry page
  <other>.html          Additional pages, flat structure
  thank-you.html        Optional post-submit confirmation
  404.html              Optional on-brand 404

  styles/main.css       Stylesheet entry (CSS variables for tokens)
  scripts/main.js       JS entry, kept minimal

  assets/
    fonts/              Self-hosted fonts
    images/             Optimized to WebP, responsive sizes
    icons/              SVG logos and favicons

  forms/contact.php     PHP mail handler for cPanel-style hosts
                        (omit if using Netlify Forms or Formspree)

  deploy/
    deploy.sh           lftp FTP mirror to host
    .env.example        FTP_HOST, FTP_USER, FTP_PASS, FTP_REMOTE_DIR

  sitemap.xml
  robots.txt
```

Multi-page sites use a flat structure (no `pages/` subfolder). URLs are `/about.html`, `/projects.html`, etc. Keep `index.html` at the root.

## Hosting profiles

Primary: cPanel-style FTP host (JoshWho, traditional shared hosting).

- Deploy via `./deploy/deploy.sh` (lftp mirror). The script excludes `.git`, the
  root context trio, `README.md`, `deploy/`, and `.env*` from the upload.
- Forms via `forms/contact.php` (PHP `mail()` with honeypot, header-injection protection).
- Confirm Let's Encrypt SSL is enabled on the host before launch.

Alternate: Netlify (Free tier).

- Deploy via drag-and-drop or Git connect. Automatic SSL.
- Forms via Netlify Forms (no PHP). Remove `forms/contact.php` from the deploy.
- Netlify Free covers any reasonable brochure site (300 build credits/month is plenty for static sites with low push frequency).

Portable fallback: Formspree or equivalent third-party form endpoint.

- Use when the host has no PHP and Netlify is not in play.
- The form `action` is the only host-specific value in markup.

The form handler must be swappable across hosts. Do not hardcode host-specific assumptions in markup beyond the `action` attribute.

## Brand kit integration

Static-web sites consume the brand kit through CSS variables, no Style Dictionary required.

- Tokens: declare brand primitives as CSS custom properties in `:root` (in `styles/main.css` or a `styles/tokens.css` partial). Use OKLCH where the brand kit defines it; fall back to hex.
- Per-entity overrides: under `[data-brand="<entity>"]` selectors, mirroring `theme/theme-standard.md`.
- Semantic tokens: define `--color-bg`, `--color-fg`, `--color-accent`, `--color-muted`, `--color-link`, etc. Components reference semantic tokens only.
- Dark mode: optional. If used, override semantic tokens under `:root.dark` or `@media (prefers-color-scheme: dark)`.

Cross-reference: see `theme/theme-standard.md` for the full three-layer model. Static-web omits the Tailwind v4 and shadcn layers; the tokens and semantic layers apply.

## Performance budget

- Lighthouse mobile performance: 90 or higher. Block ship below.
- First contentful paint under 2 seconds on simulated 4G.
- Home page total weight under 1 MB excluding optional below-fold video.
- No auto-loading multi-megabyte hero video. If a hero clip is used, lazy-load with a poster image and serve a compressed WebM or MP4.
- All raster images: WebP, responsive `srcset`, lazy-loaded below the fold.
- Fonts: self-hosted, `font-display: swap`, subset where practical.
- No render-blocking third-party scripts. Analytics is the typical offender; load it `defer` or `async`.

## Accessibility minimum

WCAG 2.1 AA.

- Semantic HTML (`header`, `nav`, `main`, `footer`, `article`, `section`).
- One H1 per page; logical heading order with no skipped levels.
- Color contrast 4.5:1 for body text, 3:1 for large text and UI components.
- All interactive elements keyboard reachable with a visible focus state.
- Real `alt` text on content images; empty `alt=""` on decorative images.
- Touch targets 44x44 px minimum for primary actions.
- Forms: labels associated with inputs, error states announced, no placeholder-as-label.
- Motion: respect `prefers-reduced-motion`.

## SEO baseline

- `<title>` and `<meta name="description">` per page, distinct and useful.
- Canonical link per page.
- Open Graph and Twitter card tags (title, description, image, type, url).
- One H1 per page.
- `sitemap.xml` lists every public page.
- `robots.txt` allows crawling and references the sitemap.
- Schema.org JSON-LD where relevant (LocalBusiness, ProfessionalService, Organization, FAQ).
- Descriptive, kebab-case URLs.

## Security headers

Static hosts can set headers either at the host config level (`.htaccess` for Apache/cPanel, `_headers` for Netlify) or, as a fallback, via `<meta http-equiv>` tags for the subset that supports it.

Minimum recommended:

- `Strict-Transport-Security: max-age=31536000; includeSubDomains` (host-set only; no meta equivalent).
- `X-Content-Type-Options: nosniff`.
- `Referrer-Policy: strict-origin-when-cross-origin`.
- `Permissions-Policy` restricting unused features (camera, microphone, geolocation, payment).
- `Content-Security-Policy` where practical. Brochure sites with self-hosted assets can usually adopt a strict-ish policy; audit any third-party scripts (analytics, embedded fonts) before authoring.

Reference snippets:

- `static-web/examples/htaccess.example` for Apache/cPanel hosts.
- `static-web/examples/netlify-headers.example` for Netlify.

## Contact form patterns

PHP mailer (`forms/contact.php`):

- POST only; reject other methods with 405.
- Validate required fields and email format.
- Honeypot field hidden via CSS; bots fill it, humans do not.
- Strip CR and LF from any value used in mail headers (header-injection protection).
- Redirect to `/thank-you.html` on success.

Netlify Forms:

- Add `data-netlify="true"` and a hidden `form-name` input to the form markup.
- Add a hidden honeypot input named `bot-field`.
- Configure email or webhook notifications in the Netlify dashboard.

Formspree (or equivalent):

- Point the form `action` to the endpoint URL.
- Add an `_gotcha` honeypot input.

Convention: name the honeypot input `website` regardless of handler so a single CSS rule (`input[name="website"] { display: none; }`) hides it everywhere.

## Pre-ship checklist

- Lighthouse mobile performance 90+, accessibility 90+, SEO 90+.
- All raster images optimized to WebP with `srcset`.
- Fonts self-hosted, `font-display: swap`.
- One H1 per page; heading order logical.
- Color contrast verified for primary text, links, and UI.
- Keyboard navigation works; visible focus throughout.
- Touch targets 44x44 minimum for primary actions.
- Forms: labels associated, validation messages clear, honeypot in place.
- Contact form submitted end to end and the email actually arrived.
- `sitemap.xml` and `robots.txt` present and correct.
- Open Graph, Twitter, and canonical tags per page.
- Security headers set on the host (`.htaccess` or `_headers`).
- SSL active on the production domain.
- `404.html` present and on-brand.
- All `TODO`, "Lorem ipsum", and placeholder copy removed.
- `.env` not committed; secrets only in `deploy/.env` (gitignored).
