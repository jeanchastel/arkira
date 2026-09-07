# STATIC-WEB

Standards and install path for static HTML/CSS brochure and marketing sites.

## Why separate from the app standards

The app-oriented standards (`THEME`, `VERCEL`, `SUPABASE`, `MOBILE`, `SECURITY`) assume a build pipeline, runtime secrets, and an application surface. Brochure sites have none of that. Forcing them through `/arkira-init` pulls in switches and conventions that do not apply.

`STATIC-WEB` is the lean install path for sites where `index.html` + assets + an FTP push (or a static deploy) ships the product.

## Contents

- `static-web-standard.md`. The canonical standard: when to use it, project layout, hosting profiles, brand-kit integration, performance budget, accessibility, SEO, security headers, contact form patterns, pre-ship checklist.
- `switches.json`. The slim switch set asked during `/arkira-init-web`.
- `scripts/arkira-init-web.sh`. The on-disk writer invoked by the install command.
- `examples/htaccess.example`. Reference security headers for Apache/cPanel hosts.
- `examples/netlify-headers.example`. Reference security headers for Netlify (`_headers`).

## Install

Inside a static-web repo:

```
/arkira-init-web
```

The wizard asks a small set of questions, writes `.arkira/config.json` flagged as `profile = "static-web"`, optionally scaffolds the canonical layout, and writes the root context trio. `AGENTS.md` is the shared project brief. `CLAUDE.md` and `CODEX.md` are exact canonical pointer overlays.

Run with `--dry-run` to preview changes without touching disk. Run with `--no-scaffold` to write only the config and root context trio.

## Updates and drift

`/arkira-sync` reports drift between the repo and `static-web-standard.md`, the same way it does for the app standards. Apply changes through normal review.
