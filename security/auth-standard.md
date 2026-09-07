# SaaS Authentication and Authorization Standard

## Purpose

Define the baseline authentication, authorization, session, and tenant-access model for Arkira-governed SaaS applications.

## Scope

Applies to:

- SaaS platforms
- internal multi-user apps
- Supabase-backed applications
- Vercel-hosted applications
- AI-assisted MVPs that may become production systems

## Standards References

Use these standards as the external baseline:

- OWASP Application Security Verification Standard
- OWASP Authentication Cheat Sheet
- OWASP Authorization Cheat Sheet
- OWASP Session Management Cheat Sheet
- NIST SP 800-63 Revision 4
- Supabase Row Level Security documentation
- Supabase Auth documentation
- Supabase Server-Side Auth guide for Next.js (`@supabase/ssr`)

## Default Auth Stack

Pick the auth provider by data layer, not by preference.

For Supabase-backed applications, Supabase Auth is the default. Identity flows directly into Row Level Security through `auth.uid()`, so authentication and authorization share one system. This is the standard choice for the Arkira Next.js plus Supabase stack.

Deviation requires a documented exception. Acceptable reasons:

- the application does not use Supabase as its primary data store
- auth must be decoupled from the data layer for a stated architectural reason
- an enterprise requirement such as SAML or SCIM is better served by a dedicated provider

Approved alternates, in order of preference, when an exception applies:

- Better Auth for owned, in-repo auth code in any TypeScript app
- Auth.js, formerly NextAuth, for Next.js apps not backed by Supabase; it is now maintained by the Better Auth team and is in security-patch mode, so prefer Better Auth for new work
- WorkOS when enterprise SSO and SCIM provisioning are first-class needs

One application runs exactly one auth system. Running Supabase Auth and Auth.js together is a defect, not a migration step.

## Core Doctrine

Authentication answers:

- who are you?

Session management answers:

- how do we remember you safely?

Authorization answers:

- what are you allowed to access?

Tenant authorization answers:

- what are you allowed to access inside this organization, workspace, account, or tenant?

## SaaS Rule

User identity is not enough.

Every protected action must prove:

- authenticated user
- tenant or workspace membership
- role or permission
- resource ownership or access rights

## Required Model

Use this conceptual model unless a documented exception exists:

```text
User
→ Organization / Workspace / Tenant
→ Membership
→ Role
→ Permission
→ Resource
```

## Required Tables

For Supabase-backed SaaS platforms, prefer:

```text
profiles
organizations
organization_memberships
roles or role enum
resources owned by organization_id
```

Optional for larger systems:

```text
permissions
role_permissions
audit_logs
admin_actions
support_access_sessions
```

## Platform Roles vs Tenant Roles

Platform roles control access across the SaaS platform.

Tenant roles control access inside one organization, workspace, account, or tenant.

Do not merge these concepts.

### Platform Roles

Examples:

- user
- support_admin
- super_admin

### Tenant Roles

Examples:

- owner
- admin
- member
- viewer
- client

## Do Not

- authorize only by `user_id` in a multi-tenant app
- rely on frontend UI state as a security boundary
- trust client-side role values
- expose service-role keys to the browser
- bypass RLS casually
- mix platform roles and tenant roles
- treat authentication as authorization
- allow cross-tenant resource access without explicit policy
- run more than one auth system in a single application
- adopt a non-default auth provider without a documented exception

## Frontend Responsibilities

Frontend may:

- guide user experience
- hide unavailable actions
- redirect unauthenticated users
- show role-aware navigation
- improve usability

Frontend must not:

- serve as the final access-control layer
- store trusted authorization state
- expose privileged secrets
- decide tenant access without server/database enforcement

## Server Responsibilities

Server-side logic must:

- verify the authenticated user
- verify tenant membership
- verify role or permission
- validate resource ownership
- protect mutations
- fail securely

## Database Responsibilities

Database policy should:

- deny by default
- enforce tenant boundaries
- enforce row ownership
- enforce membership-based access
- protect exposed tables with RLS

## Supabase RLS Rules

For tables in exposed schemas:

- enable RLS
- create explicit policies
- scope policies to authenticated users where appropriate
- use `auth.uid()` explicitly
- enforce `organization_id` or owner access where applicable

Preferred policy logic should include:

```sql
(select auth.uid()) is not null
```

and should verify membership or ownership.

## Service Role Rules

The service-role key is technical authority.

It is not a user role.

Do not:

- expose service-role keys to the browser
- use service-role keys in client-side code
- use service-role keys to avoid proper authorization design
- treat service-role access as normal application access

Use service-role access only for:

- controlled server-side admin operations
- migrations
- background jobs
- trusted system tasks

## Session Rules

Sessions should:

- be managed by trusted auth providers or frameworks
- use secure transport
- avoid exposing sensitive session data to client-side scripts
- expire appropriately
- be renewed or invalidated after privilege changes where supported

Do not:

- invent custom session systems casually
- store sensitive auth tokens in unsafe browser storage
- treat a valid session as sufficient authorization

## Next.js Integration

For Next.js App Router applications on Supabase:

- use `@supabase/ssr` for cookie-based sessions
- create separate server and browser Supabase clients
- read and refresh the session in the proxy (`proxy.ts`, formerly `middleware.ts`)
- enforce access in Server Components, server actions, and route handlers
- never treat session state in a Client Component as an access boundary

Do not:

- use the deprecated `@supabase/auth-helpers-nextjs` package in new work
- call the service-role client from any browser-reachable code path
- gate protected behavior on client-side redirects alone

## Reauthentication Rules

Require reauthentication or additional verification for sensitive actions where practical.

Examples:

- password change
- email change
- billing changes
- role changes
- organization ownership transfer
- destructive admin actions

## Environment Rules

Separate:

- local development
- preview deployments
- production deployments

Do not:

- share production secrets with preview environments by default
- assume preview and production auth behavior are identical
- allow production-only privileged access in development code paths

Legacy Supabase `anon` and `service_role` API keys keep working only until the end of 2026. Plan rotation to the current Supabase key model before that deadline, and verify production and preview each carry the correct keys.

## Validation Required

Auth-sensitive changes should verify:

- unauthenticated access is denied
- authenticated access is allowed only where intended
- cross-tenant access is denied
- wrong-role access is denied
- owner/admin/member/viewer behavior is correct
- RLS blocks unauthorized data access
- server-side checks match database policies

## Minimum SaaS Auth Checklist

Before production, verify:

- managed auth is configured
- RLS is enabled on exposed tables
- tenant membership is modeled
- roles are defined
- server-side authorization exists
- service-role key is server-only
- production and preview secrets are separated
- protected routes fail securely
- protected API mutations enforce access
- cross-tenant access tests exist or are manually verified
- the default auth provider is used, or a documented exception records the deviation
- exactly one auth system is wired in the app
- Next.js apps use `@supabase/ssr`, not the deprecated auth-helpers package

## Failure Conditions

Use the canonical P0 to P3 scale from the Severity Classes block in `ai-engineering/root/AGENTS.md`; these auth conditions refine that scale for authentication and authorization failures.

Classify as `P0 Critical`:

- service-role key exposed to client
- unauthenticated access to private data
- cross-tenant data exposure
- missing authorization on protected mutations
- RLS disabled on exposed sensitive tables

Classify as `P1 High`:

- frontend-only authorization
- unclear tenant model
- inconsistent role enforcement
- missing auth validation tests
- preview/production auth confusion
- two auth systems wired into one application
- a non-default auth provider adopted without a documented exception

## Reference Implementation

A hardened reference lives at `examples/auth-reference/`. It implements this
standard: Supabase Auth, `@supabase/ssr` clients and proxy-based session refresh, the
`organizations` + `org_members` tenant model, `is_member()` / `is_admin()` RLS
helpers with deny-by-default policies, server-side context helpers, an audited
service-role boundary, reauthentication for sensitive actions, and a cross-tenant
RLS test matrix. Adopt by copying it and adding your own resources on the
`projects` shape.


## Final Standard

Frontend protects experience.

Server protects behavior.

Database protects data.
