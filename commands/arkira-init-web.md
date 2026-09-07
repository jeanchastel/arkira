---
description: Slim setup wizard for static brochure website repos. Asks a small set of static-web switches, optionally scaffolds the canonical layout. No app-oriented toolchain (no Supabase, Vercel, mobile).
---

# /arkira-init-web

Run the Arkira static-web onboarding wizard for a brochure-site repo. Collect the small set of choices that matter for a static site, optionally scaffold the canonical project layout, and write the shared `AGENTS.md` project brief, exact `CLAUDE.md` and `CODEX.md` pointer overlays, plus `.arkira/config.json`. Does not pull in app-oriented switches.

For application repos, use `/arkira-init` instead.

## Behavior

- `/arkira-init-web` (no arguments): run the interactive wizard and scaffold any missing project files.
- `/arkira-init-web --dry-run`: run the wizard but stop after presenting the diff. Touches no disk.
- `/arkira-init-web --no-scaffold`: write `.arkira/config.json` and the three root context files only. `AGENTS.md` owns the shared project brief; `CLAUDE.md` and `CODEX.md` are exact pointer overlays. Do not create site files.

## Steps

1. Resolve the target repo root:
   `git rev-parse --show-toplevel`. If this fails, tell the user to `git init` first and stop.

2. Read the static-web switch inventory:
   `cat "${CLAUDE_PLUGIN_ROOT}/static-web/switches.json"`. Parse the JSON.

3. Print the disclosure card:

   Arkira static-web setup. Lean install for static HTML brochure sites. No Supabase, no Vercel, no mobile. Covers project layout, hosting, contact forms, performance budget, accessibility, SEO, and security headers per `static-web/static-web-standard.md`. You can opt out of any switch below. Defaults are highlighted.

4. For each switch in `static-web/switches.json`, ask the user one question. Highlight the default. Track answers as a `{id: boolean}` map.

5. After the switches, ask the site-shape questions:

   - `site_kind`: "Single page or multi-page?" Options: `single` (default), `multi`.
   - `host_primary`: "Primary deploy target?" Options: `joshwho-ftp` (default), `netlify`, `formspree-only`.
   - `form_handler`: "Contact form handler?" Options: `php` (cPanel default), `netlify`, `formspree`, `none`. Default infers from `host_primary` (php for joshwho-ftp, netlify for netlify, formspree for formspree-only).
   - `entity_brand`: "Entity for the brand override (used as the `data-brand` attribute on `<body>`, leave blank to set later)." Free text.

6. Build the decisions JSON in memory using the `standards_version` from the plugin's `VERSION.md`:

   ```json
   {
     "schema_version": 1,
     "profile": "static-web",
     "standards_version": "<plugin VERSION.md value>",
     "site_kind": "single",
     "host_primary": "joshwho-ftp",
     "form_handler": "php",
     "entity_brand": "",
     "switches": {
       "static_web_baseline": true,
       "performance_budget": true,
       "accessibility_aa": true,
       "security_headers": true,
       "honeypot_forms": true
     }
   }
   ```

7. Dry-run first to compute the diff:

   ```bash
   printf '%s' '<decisions JSON>' | \
     bash "${CLAUDE_PLUGIN_ROOT}/static-web/scripts/arkira-init-web.sh" \
       --repo-root "<repo_root>" --dry-run
   ```

   The script reports every planned write (`WRITE`, `SKIP (exists)`, `MKDIR`, `NOTE`). Show the full output to the user. Existing files are never overwritten by the scaffold; the script reports them as `SKIP`.

   If the user passed `--no-scaffold`, append it to the script invocation.

8. If the user invoked the command with `--dry-run`, stop here.

9. Ask for confirmation: `Apply these changes? [y/N]`.

10. On `y`, apply:

    ```bash
    printf '%s' '<decisions JSON>' | \
      bash "${CLAUDE_PLUGIN_ROOT}/static-web/scripts/arkira-init-web.sh" \
        --repo-root "<repo_root>" --apply
    ```

    Show the output and a one-line summary like `Arkira static-web configured for <repo_root>.`

11. On `N`, say `Aborted. No changes made.` and stop.

## What the scaffold produces

When the scaffold runs, the script writes (only files that do not already exist):

- `AGENTS.md` shared project brief with the static-web profile block.
- Exact canonical `CLAUDE.md` and `CODEX.md` pointer overlays. They contain no
  duplicated project context.
- `README.md` with local preview and deploy instructions.
- `.gitignore`, `sitemap.xml`, `robots.txt`.
- `index.html` minimal entry page (with `data-brand` if entity provided).
- `styles/main.css` with the token layer and the honeypot rule.
- `scripts/main.js` placeholder.
- `assets/{fonts,images,icons}/` directories with `.gitkeep`.
- Host-specific:
  - `joshwho-ftp`: `deploy/deploy.sh` (lftp FTP mirror), `deploy/.env.example`, and `.htaccess` (security headers, copied from `static-web/examples/htaccess.example`) if `security_headers` is on.
  - `netlify`: `_headers` (copied from `static-web/examples/netlify-headers.example`) if `security_headers` is on.
- Form-handler-specific:
  - `php`: `forms/contact.php` and `thank-you.html`.
  - `netlify`, `formspree`, `none`: no in-repo handler, just a `NOTE` in the plan.

## Notes

- The scaffold script is the only command that writes to disk. Claude does the Q&A and diff display, but only that script touches files.
- `--dry-run` makes the wizard safe to demo without committing the user to anything.
- The scaffold never overwrites existing files. Re-running `/arkira-init-web` is safe.
- Fresh and `--no-scaffold` installs always target the complete root context
  trio. Existing regular files remain byte-identical and keep their modes.
- All targets follow `governance/file-management-standard.md`: symlink redirects are
  rejected, writes are atomic, skipped files keep their modes, and a failed
  multi-file apply restores the prior config and removes its partial scaffold.
- The script requires `jq`. If it is missing, the script exits with a clear error.
- Drift checks happen via `/arkira-sync`, the same as the app standards.
- For application repos, use `/arkira-init` instead. `static-web` is a separate profile.
