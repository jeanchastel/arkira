---
name: supabase-cli
description: "Use the Supabase CLI as the primary connector for Supabase work: migrations, db push/reset/diff/pull, type generation, edge functions, secrets, storage, advisors, and branches. Triggers on Supabase database, auth, migration, or edge-function tasks. MCP and REST are fallbacks only."
paths:
  - "supabase/**"
  - "**/supabase/**"
  - "**/supabase/config.toml"
origin: arkira
---

# Supabase CLI-First

Operationalizes `supabase/cli-first-standard.md` and the `cli_first_connectors`
switch. When working with Supabase, prefer the `supabase` CLI.

## Rule

All Supabase interactions use the `supabase` CLI as the primary connector. The MCP
server and the REST or Management API are fallbacks, used only when the CLI cannot
perform the operation.

## Common commands

- Local stack: `supabase start`, `supabase stop`, `supabase db reset`
- Migrations: `supabase migration new <name>`, `supabase db push`, `supabase db diff`, `supabase db pull`
- Types: `supabase gen types --lang=typescript --linked > types/supabase.ts`
- Edge functions: `supabase functions deploy <name>`, `supabase functions list`
- Secrets and storage: `supabase secrets set KEY=value`, `supabase storage ls`
- Advisors: `supabase db advisors`

Always pass `--linked` or `--project-ref <ref>` when targeting a remote project;
never rely on ambient linkage in CI.

## Fallback

Use the MCP server or REST API only for capabilities the CLI does not expose. See
`supabase/cli-first-standard.md` for the full command table and the fallback list.

## Scoped Auth password reset

Existing Supabase Auth passwords cannot be recovered. They can only be replaced.

An agent may reset one password through the canonical
`skills/supabase-cli/scripts/reset-auth-password.sh` wrapper. Before dispatch, show one warning
that names the exact project reference, exact user email or UUID, `reset Supabase Auth password`
action, and password mode. State that the operation mutates production authentication data and
that the existing password cannot be recovered. For generated mode, state that the replacement
will appear once after success and can remain in terminal scrollback or the agent transcript.

Require a new explicit confirmation after that complete warning. Confirmation binds one project,
one exact user, one password mode, and one invocation. Any changed value or retry requires another
warning and confirmation.

After confirmation, generated mode uses:

```text
skills/supabase-cli/scripts/reset-auth-password.sh \
  --project-ref <project-ref> \
  --user-email <exact-email> \
  --password-source generate \
  --reveal-generated yes \
  --confirm-action reset-password
```

The exact `--user-id <uuid>` selector may replace `--user-email`. Do not supply both.

An operator who wants the replacement kept out of agent output runs the same wrapper directly
with `--password-source prompt` and no `--reveal-generated` flag. The wrapper reads the replacement
twice through hidden terminal input.

This is the only pre-approved agent path. Raw `supabase projects api-keys`, direct GoTrue Admin
requests, caller-supplied service-role credentials, copied wrappers, alternate actions, shell
evaluation, and output redirection remain blocked. Repositories may disable this path or require
stronger approval. They cannot remove the warning, lower the tier, permit password extraction,
expose raw keys, or broaden the fixed action.

## Divergent migration history

`supabase db push` is only safe when the repo's migration history matches
production. If `supabase migration list --linked` shows prod-only timestamped
migrations, the history has diverged: `db push` is prohibited there. Apply one
migration file with guard-railed raw `psql` over the session pooler instead. See
"Applying migrations to a divergent-history project" in
`supabase/cli-first-standard.md`.
