# Environment Variable Standard

## Purpose

Define environment variable handling standards for Arkira-governed applications.

## Scope

Applies to:

- Vercel applications
- Supabase-backed applications
- SaaS platforms
- serverless functions
- API integrations
- AI-assisted repositories

## Core Doctrine

Environment variables are part of the security boundary.

Treat environment configuration as production infrastructure, not casual project setup.

## Environment Types

Use clear separation between:

- local development
- preview deployments
- staging where applicable
- production

## Required Rules

Environment variables should be:

- documented
- scoped by environment
- named consistently
- reviewed before production deployment
- excluded from source control

## Do Not

- commit `.env` files containing secrets
- expose server-only secrets to client bundles
- share production secrets with preview environments by default
- use service-role keys in browser code
- hardcode API keys
- assume local and production environments are identical
- rename environment variables casually

## Client-Side Variables

Client-exposed variables must be treated as public.

Do not place secrets in variables exposed to browser bundles.

For Next.js projects, assume variables prefixed for public exposure are visible to users.

## Server-Side Variables

Server-side variables may include:

- database URLs
- service-role keys
- private API keys
- webhook secrets
- signing secrets

These must remain server-only.

## Supabase Rules

Do not expose:

- service-role keys
- database passwords
- admin API secrets

Public anon keys may be used client-side only when RLS policies protect data access.

RLS must not be bypassed by relying on obscurity of client keys.

## Vercel Rules

Separate variables across:

- development
- preview
- production

Before production deployment, verify:

- required production variables exist
- preview variables do not point to production systems unless intentional
- server-only variables are not exposed to client bundles
- secrets are configured through Vercel environment settings, not source files

## Documentation Required

Each repository should document required variables in:

```text
/docs/env-vars.md
```

or equivalent.

Required documentation:

- variable name
- purpose
- required environment
- client or server exposure
- example placeholder value
- secret classification

## Validation Required

Before production deployment, verify:

- required variables are present
- production values are correct
- preview values are isolated where appropriate
- no secrets are committed
- no service-role keys are exposed client-side

## Failure Conditions

Classify as `P0 Critical`:

- service-role key exposed to client
- production secret committed to repo
- private API key exposed in browser bundle
- preview environment mutating production data unintentionally

Classify as `P1 High`:

- undocumented production variables
- unclear client/server exposure
- inconsistent variable naming
- preview/production confusion

## Final Standard

Environment configuration is operational infrastructure.

Treat it with the same discipline as code.
