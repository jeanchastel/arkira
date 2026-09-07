---
description: Adopt a client's externally-hosted project (Lovable, another git host, a dev repo) onto your own GitHub + Vercel, then onboard and apply Arkira standards, without touching live.
argument-hint: <client> <source-url-or-export-path>
---

# /intake

Take a client project hosted elsewhere and bring it fully into your own
infrastructure: pull the code local, re-home it to a fresh GitHub repo and a
fresh preview-only Vercel project, run onboarding, and apply Arkira standards.
The live deployment, the source remote, and production data are never touched.

Usage:
- `/intake <client> <source>`: run the full intake for this client. `<source>`
  is a git URL, a Lovable repo/export, or a local path.
- `/intake` (no args): ask for the client and source, then run.

## Behavior

Invoke the `intake-runbook` skill and follow it exactly. The skill carries the full
runbook and the hard invariants. Do not improvise around the invariants.

Non-negotiable invariants (the skill enumerates all six):
- Source remote is read-only. Never push back to it.
- New GitHub repo under the org resolved from `entity-map.json`.
- New Vercel project, **preview only**, no prod domain on first deploy.
- Never reuse the live Supabase / database. Stand up your own and migrate.
- Rotate any committed secret before the first push.
- Verify lint / typecheck / test green before pushing.

## Steps

1. Resolve the client in
   `~/Documents/Claude/Projects/AgenticOS/config/entity-map.json` to get the
   `github_org` and `workspace`. If absent, ask the operator for the target org.
2. Run the `intake-runbook` skill against `<source>`. It creates and proves a
   fresh contained target with the executable `intake-target.js` binder before
   clone or extraction, then chooses the history strategy by source type
   (Lovable → orphan-root squash; existing dev git → preserve). Every Git,
   verification, scan, GitHub, and deploy command is spawned from the already
   bound directory inode and revalidated afterward. Parent identity remains
   bound through target creation and private state publication. The private
   state-parent binding remains live through creation commit or rollback, which
   removes only the exact run-created inodes. It never deletes `.git`.
3. Complete onboarding, Arkira init/sync, fresh data and Vercel setup, local
   verification, and the working-tree scan. Commit the complete onboarded
   candidate, including migrations and generated types, then scan that exact
   committed history. Both scans pass before creating or pushing the new origin.
   A failed clone, verification command, or scan stops the run. A raw import
   commit is never pushed.
4. Push only to the newly created origin, deploy once at preview scope, and
   report the preview URL. Do not wire a prod domain or
   live data without an explicit follow-up from the operator.

## Notes

- This command never touches the source's live deployment, remote, or data.
  Everything lands on a fresh repo + fresh preview Vercel project under the
  client's own org.
- For a repo already in your org that only needs standards, use `/arkira-sync`
  directly instead.
