# Vercel: CLI-First Connector Standard

Status: canonical. Synced to product repos via `/arkira-sync`.

## Rule

All Vercel interactions from agentic workflows, scripts, CI jobs, and local development MUST use the `vercel` CLI as the primary connector. The Vercel MCP server, REST API, and `@vercel/sdk` are fallbacks, used only when the CLI cannot perform the operation.

## Rationale

- The CLI is the public, stable interface Vercel maintains across product changes.
- The CLI is the only path that can both deploy and inspect a project from a single command surface; the MCP server is read-heavy.
- The CLI produces deterministic stdout/stderr and exit codes, which agents can parse and which CI can gate on.
- Vercel's deployment, env, log, and domain commands all share one auth context (`vercel login`), so a single configured CLI replaces three or four API integrations.

## Canonical Commands

Use these commands as the default. They cover the large majority of agentic operations.

| Operation | Command |
|---|---|
| Authenticate | `vercel login` |
| Link a project | `vercel link` |
| Pull env for current env | `vercel env pull .env.local` |
| List env vars | `vercel env ls` |
| Add an env var | `vercel env add <name> <env>` |
| Remove an env var | `vercel env rm <name> <env>` |
| Preview deploy | `vercel` (no args) |
| Production deploy | `vercel --prod` |
| Build locally with Vercel config | `vercel build` |
| Deploy a prebuilt output | `vercel deploy --prebuilt` |
| List recent deployments | `vercel ls` |
| Read exact API evidence through native CLI auth | `vercel api <endpoint> --method GET --raw` |
| Inspect a deployment | `vercel inspect <url>` |
| Tail runtime logs | `vercel logs <url> --follow` |
| List domains | `vercel domains list` |
| Add a domain | `vercel domains add <domain> <project>` |
| Price-check a domain | `vercel domains price <domain>` |
| List projects | `vercel project list` |
| Inspect a project | `vercel project inspect <name>` |
| List teams | `vercel teams list` |
| Switch team scope | `vercel teams switch <name>` |
| Open project dashboard | `vercel open` |

Always run CLI commands from inside a linked repo, or pass `--cwd <path>`. Never rely on ambient project linkage in CI; use `VERCEL_PROJECT_ID` + `VERCEL_ORG_ID` env vars.

`vercel api` is a native CLI command, not an external REST client fallback.
Installed CLI 59.10.0 exposes it as beta. The delivery observer's exact
`/v6/deployments` GET was exercised successfully for preview and production,
filtered by project, team, Git revision and target. Use explicit scope in the
request; do not infer production success from an unrelated READY deployment.

## Fallback order

1. **CLI**: primary connector. All operations attempt the CLI first.
2. **MCP server**: used when the CLI fails (non-zero exit, missing subcommand, or feature gap) or when the CLI cannot express the operation.
3. **REST API / `@vercel/sdk`**: last resort, only when neither CLI nor MCP supports the operation.

Agents must not skip a tier. If an operation succeeds at the CLI, do not also call MCP. If MCP succeeds, do not also call REST or the SDK.

## When Fallback Is Allowed

Use the Vercel MCP server, `@vercel/sdk`, or REST API ONLY for capabilities the CLI does not expose, including:

- Toolbar / comment thread operations (`add_toolbar_reaction`, `reply_to_toolbar_thread`).
- Vercel Documentation search from inside an agent (`search_vercel_documentation`).
- Programmatic operations from a non-shell service context (a long-running app, a webhook handler, an Edge Function) where shelling out to `vercel` is impractical.

When a fallback is used, the code or script MUST include a one-line comment naming the missing CLI capability, so we can revisit when the CLI gains coverage.

```ts
// Fallback: no `vercel toolbar` CLI surface, using MCP add_toolbar_reaction.
```

## CI Standard

In GitHub Actions, prefer the CLI over the deploy action when build artifacts must be inspected:

```yaml
- run: pnpm add -g "vercel@${VERCEL_CLI_VERSION:?set a tested CLI version}"
- run: vercel pull --yes --environment=production --token=$VERCEL_TOKEN
- run: vercel build --prod --token=$VERCEL_TOKEN
- run: vercel deploy --prebuilt --prod --token=$VERCEL_TOKEN
```

Required env vars: `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID`.

## Release versioning and deployment identity

- Plan related changes as one coherent delivery unit with one integration owner.
  Produce one verified production deployment when the requested outcome requires it.
  A merge alone neither requires a new production deployment nor proves delivery.
  Use the repository's native deployment policy and preserve exact revision tracking.
- Repository SemVer in `package.json` changes only inside an intentional product change or a
  dedicated version change authored by a human. An `arkira-labs-standards` version never bumps a
  product version.
- Deployment identity is derived during the build from the deployed commit. No repository-writing
  version mechanism is introduced, and the derived value is never written back to the repository.
- No workflow writes a second version-bump commit to the default branch.

The displayed development identity is:

```
<semver>+<short-sha>
```

`<semver>` is the `package.json` version with everything from the first `+` onward stripped, so the
result never carries two `+` components. A pre-release suffix such as `-rc.1` is preserved. For
example, `1.0.412-rc.1+build.4` with short SHA `3f9ac21` displays as `1.0.412-rc.1+3f9ac21`.

Resolve `<short-sha>` in this order:

| Context | Source | Displayed identity example |
| --- | --- | --- |
| Vercel build | First seven characters of `VERCEL_GIT_COMMIT_SHA` | `1.0.412+3f9ac21` |
| GitHub Actions build | First seven characters of `GITHUB_SHA` | `1.0.412+3f9ac21` |
| Any host with Git | `git rev-parse --short=7 HEAD` | `1.0.412+8b2e0d4` |
| No Git and no environment SHA | Literal `local` | `1.0.412+local` |

## Agent Behavior

Agents operating inside an Arkira product repo must:

1. Prefer the CLI for every Vercel task they emit, generate, or recommend.
2. Treat the absence of `vercel` on `PATH` as a setup error, not a reason to fall back. Resolve the installation owner and install a tested version through that owner. Do not blindly install or upgrade `@latest` during a coding task.
3. Never embed `VERCEL_TOKEN` in code. Use repo secrets in CI and `vercel login` locally.
4. Use `vercel env pull` to sync envs to disk. Never paste env values back into the dashboard manually.
5. Verify deploys with `vercel inspect` or `vercel logs --follow` before reporting success.

## Related

- `security/environment-variable-standard.md`
- `github/ci-validation-standard.md`
- `supabase/cli-first-standard.md`
- `tooling/package-manager-standard.md`
