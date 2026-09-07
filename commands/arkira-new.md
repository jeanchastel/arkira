---
description: "Bootstrap a brand-new project from a brief: wizard, scaffold with the canonical generator, apply Arkira standards, and provision GitHub, Vercel, and Supabase at preview scope. Greenfield counterpart to /intake."
argument-hint: "[brief-or-path]"
---

# /arkira-new

Take a project brief and stand up a brand-new project: run a short wizard,
scaffold with the official stack generator, apply Arkira standards, and provision
GitHub, Vercel, and (when needed) Supabase. Everything stops at preview scope. No
prod domain, no prod data.

Usage:
- `/arkira-new <brief>`: brief as inline text.
- `/arkira-new <path>`: brief read from a file.
- `/arkira-new` (no args): ask for the brief, then run.

## Behavior

Invoke the `arkira-new-runbook` skill and follow it exactly. The skill carries the full
runbook and the hard invariants. Do not improvise around the invariants.

Non-negotiable invariants (the skill enumerates all five):
- Preview only on first run. No prod domain, no prod Supabase, no promotion.
- New private GitHub repo under the org resolved from `entity-map.json`.
- Always create fresh cloud resources; never adopt a live project.
- Secrets scanned before the first push; rotate and rescan on any hit.
- Verify lint / typecheck / build green before the commit and push.

## Notes

- The greenfield counterpart to `/intake`. `/intake` adopts existing code;
  `/arkira-new` starts from a brief.
- For a repo that already exists and only needs standards, use `/arkira-sync`.
- Native iOS/Android is not scaffolded here; run `native-scaffold` after the web
  app exists.
