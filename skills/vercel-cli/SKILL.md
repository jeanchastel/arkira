---
name: vercel-cli
description: "Use the Vercel CLI as the primary connector for Vercel work: deployments, env vars, logs, domains, projects, and teams. Triggers on Vercel deploy, environment, build, domain, or runtime-log tasks. MCP, REST, and the SDK are fallbacks only."
paths:
  - "vercel.json"
  - "**/vercel.json"
  - ".vercel/**"
origin: arkira
---

# Vercel CLI-First

Operationalizes `vercel/cli-first-standard.md` and the `cli_first_connectors`
switch. When working with Vercel, prefer the `vercel` CLI.

## Rule

All Vercel interactions use the `vercel` CLI as the primary connector. The MCP
server, REST API, and `@vercel/sdk` are fallbacks, used only when the CLI cannot
perform the operation.

## Common commands

- Deploy: `vercel` (preview), `vercel --prod` (production), `vercel build`, `vercel deploy --prebuilt`
- Env: `vercel env pull .env.local`, `vercel env ls`, `vercel env add <name> <env>`
- Inspect: `vercel ls`, `vercel inspect <url>`, `vercel logs <url> --follow`
- Domains: `vercel domains list`, `vercel domains add <domain> <project>`
- Projects and teams: `vercel project list`, `vercel teams switch <name>`

Run from inside a linked repo or pass `--cwd <path>`; in CI use `VERCEL_PROJECT_ID`
and `VERCEL_ORG_ID` rather than ambient linkage.

## Fallback

Use the MCP server, REST API, or SDK only for capabilities the CLI does not expose.
See `vercel/cli-first-standard.md` for the full command table.
