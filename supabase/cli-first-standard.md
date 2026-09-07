# Supabase: CLI-First Connector Standard

Status: canonical. Synced to product repos via `/arkira-sync`.

## Rule

All Supabase interactions from agentic workflows, scripts, CI jobs, and local development MUST use the `supabase` CLI as the primary connector. MCP servers and the REST/Management API are fallbacks, used only when the CLI cannot perform the operation.

## Rationale

- The CLI is the public, stable, versioned surface area Supabase guarantees.
- The CLI works against a local stack (`supabase start`) and an arbitrary remote project (`supabase link`), so the same commands run in dev, CI, and production.
- The CLI produces deterministic stdout/stderr and exit codes, which agents can parse and which CI can gate on.
- MCP servers and REST API calls require ambient credentials, add an indirection layer, and are easier to misuse from an agent.

## Canonical Commands

Use these commands as the default. They cover the large majority of agentic operations.

| Operation | Command |
|---|---|
| Start local stack | `supabase start` |
| Stop local stack | `supabase stop` |
| Link a remote project | `supabase link --project-ref <ref>` |
| Create a new migration | `supabase migration new <name>` |
| Push migrations to remote | `supabase db push` |
| Reset local DB to migrations | `supabase db reset` |
| Diff local DB vs migrations | `supabase db diff` |
| Pull remote schema as migration | `supabase db pull` |
| Generate TypeScript types | `supabase gen types --lang=typescript --linked > types/supabase.ts` |
| Deploy an Edge Function | `supabase functions deploy <name>` |
| List functions | `supabase functions list` |
| Set function secrets | `supabase secrets set KEY=value` |
| List storage objects | `supabase storage ls` |
| Run security and performance advisors | `supabase db advisors` |
| Manage organizations | `supabase orgs list`, `supabase orgs create` |
| Manage projects | `supabase projects list`, `supabase projects create`, `supabase projects delete` |
| Manage preview branches | `supabase branches list`, `supabase branches pause`, `supabase branches unpause` |

Always pass `--linked` or `--project-ref <ref>` explicitly when targeting a remote project. Never rely on ambient project linkage in CI.

`supabase db push` assumes the repo's migration history matches production. When production history has diverged (prod-only timestamped migrations), see "Applying migrations to a divergent-history project" below; `db push` is prohibited there.

## Fallback order

1. **CLI**: primary connector. All operations attempt the CLI first.
2. **MCP server**: used when the CLI fails (non-zero exit, missing subcommand, or feature gap) or when the CLI cannot express the operation.
3. **REST/Management API**: last resort, only when neither CLI nor MCP supports the operation.

Agents must not skip a tier. If an operation succeeds at the CLI, do not also call MCP. If MCP succeeds, do not also call REST.

## When Fallback Is Allowed

Use the MCP server or REST API ONLY for capabilities the CLI does not expose, including:

- Querying organization billing or cost (`get_cost`, `confirm_cost`).
- Tailing hosted Edge Function logs (no `supabase functions logs` subcommand exists; the CLI only supports `serve` locally).
- Anything the installed `supabase --help` command tree does not expose.

When a fallback is used, the code or script MUST include a one-line comment naming the missing CLI command, so we can revisit when the CLI gains coverage.

```ts
// Fallback: no `supabase functions logs` CLI subcommand, using MCP get_logs.
```

## Applying migrations to a divergent-history project

`supabase db push` is canonical **only when the repo's migration history matches production**. Confirm with `supabase migration list --linked`: if production shows timestamped migrations that are not in the repo, the history has **diverged**.

On a divergent-history project, `db push` is unsafe and prohibited. It tries to reconcile the whole chain and can clobber or fail against prod-only migrations. The Management-API / PAT fallback is also unreliable here: personal access tokens (`sbp_...`) 401 and need frequent re-minting. Use the raw-`psql`-per-file method instead.

### When this path is sanctioned

Either condition alone makes it the correct method:

- Production migration history has diverged from the repo (prod-only migrations).
- The CLI or PAT path is unavailable (CLI cannot reach prod, or the PAT keeps 401ing).

Outside these, `supabase db push` remains the only sanctioned path.

### Method


1. Install a client: `brew install libpq` (`psql` at `<brew-prefix>/opt/libpq/bin/psql`, e.g. `/usr/local/opt/libpq/bin/psql`).
2. Connect over the **session pooler**, not the direct host. `db.<ref>.supabase.co` is IPv6-only and does not resolve on IPv4 networks. Keep connection settings in a `chmod 600` env file:

   ```
   PGHOST=aws-0-<region>.pooler.supabase.com
   PGPORT=5432
   PGUSER=postgres.<ref>
   PGDATABASE=postgres
   PGSSLMODE=require
   PGPASSWORD=<long-lived DB password>
   ```

   Authenticate with the long-lived **DB password**, never a PAT. The password changes only on a dashboard reset, and is safe to hold this way: the app connects via the anon and service-role keys, never this password. Source the env file from a `chmod 700` wrapper so the secret never lands on the command line or in shell history.
3. Apply one migration file, all-or-nothing:

   ```
   psql --single-transaction -v ON_ERROR_STOP=1 -f <migration>.sql
   ```

   One file per run. `--single-transaction` rolls back the whole file on any error; `ON_ERROR_STOP=1` aborts on the first failed statement.

**Caveat:** `create policy` is not idempotent (no `IF NOT EXISTS`). Guard it, or run the file exactly once; a re-run fails on the existing policy.

## Ordering migrations relative to code deploys

A migration and the code that depends on it deploy at different moments. Order them so neither the old code nor the new code ever meets a schema it cannot handle. Split every change into two directions.

**Additive (expand): apply to the database before deploying code.** New tables, new columns, new indexes, new enum values, and new permissive or nullable structures are additive. Push them first. Code already in production ignores what it does not reference, and the new code arrives to a schema that is already ready. Running `supabase db push` before the deploy is the default for this direction.

**Subtractive (contract): apply to the database after deploying code.** Dropping a table or column, removing an enum value, tightening a column to `NOT NULL`, and adding a restrictive constraint are subtractive. Deploy the code that no longer depends on the object first, confirm it is live, then push the migration. Reverse this and the still-running old code hits a missing or newly-constrained object and breaks.

**Renames and type changes are both directions, never one migration.** A rename is a drop plus an add, so run it as expand then contract: add the new column, ship code that writes both and reads the new one, deploy, backfill, then drop the old column in a later migration. Same for a nullable-to-`NOT NULL` change: add nullable (expand), backfill, deploy code that always writes it, then add the constraint (contract).

This keeps every deploy backward-compatible with the schema on either side of it, which is also what makes a rollback safe: reverting code never lands on a schema the old code cannot read.

## Agent Behavior

Agents operating inside an Arkira product repo must:

1. Prefer the CLI for every Supabase task they emit, generate, or recommend.
2. Treat the absence of `supabase` on `PATH` as a setup error, not a reason to fall back. Tell the user to install the CLI.
3. Never embed Supabase service-role keys in code. Use `supabase secrets set` for Edge Function secrets and project-level env vars for application code.
4. Apply migrations through `supabase db push` (or the project's wrapper) by default. Do not run raw `psql` against production **except** on a divergent-history project, where `db push` is prohibited and the guard-railed single-file `psql` method above is the sanctioned path: session pooler host, long-lived DB password (never a PAT), `psql --single-transaction -v ON_ERROR_STOP=1 -f <file>.sql`, one file per run. Ad-hoc `psql` against production (multi-statement pastes, no single transaction, no `ON_ERROR_STOP`) remains forbidden.
5. Order migrations against the deploy per "Ordering migrations relative to code deploys": additive changes pushed before the code deploy, subtractive changes after it, renames and type tightenings split into an expand migration then a later contract migration.

## Related

- `security/environment-variable-standard.md`
- `security/auth-standard.md`
- `vercel/cli-first-standard.md`
