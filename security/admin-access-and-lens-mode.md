# Admin Access and Lens Mode Standard

## Purpose

Define platform-admin access, support access, impersonation controls, and development lens-mode behavior for Arkira-governed SaaS applications.

## Scope

Applies to:

- SaaS platforms
- internal admin tooling
- support workflows
- preview deployments
- QA environments
- Supabase-backed systems

## Core Doctrine

Development tools are not production access models.

Lens Mode is a development and QA tool.

Production access must remain:

- explicit
- logged
- reviewable
- operationally constrained

## Definitions

### Platform Role

A role with authority across the SaaS platform.

Examples:

- support_admin
- super_admin

### Tenant Role

A role scoped to one organization, workspace, or tenant.

Examples:

- owner
- admin
- member
- viewer

### Lens Mode

A controlled mechanism for viewing or testing the application as another role, tenant, or user experience.

Lens Mode is not true identity replacement.

## Required Separation

Do not merge:

- platform authority
- tenant authority
- impersonation state
- service-role authority

These are separate concepts.

## Super Admin Rules

Super Admin may:

- inspect platform-level operational state
- access cross-tenant administration tools
- perform controlled support actions
- manage platform configuration

Super Admin must not:

- silently impersonate users
- bypass audit visibility
- rely on frontend-only controls
- use service-role authority from the browser

## Lens Mode Rules

Lens Mode should:

- exist primarily in development and QA
- be explicit and visible
- be easy to exit
- preserve the true acting user
- be logged where practical

Lens Mode must not:

- silently replace user identity
- obscure audit trails
- bypass server-side authorization
- bypass database policies

## Required Lens Banner

When Lens Mode is active, show a persistent indicator.

Examples:

```text
Viewing as: Member
Viewing as: Tenant Admin
Viewing as: Client
```

## Actor vs Effective User

Systems using Lens Mode should preserve:

```text
actor_user_id
```

and:

```text
effective_user_id
```

The real operator must always remain identifiable.

## Production Rules

Production Lens Mode should be:

- disabled by default
- restricted heavily
- enabled only for documented support workflows

Preferred production model:

- support tooling
- test accounts
- preview deployments
- seeded QA tenants

## Preview and QA Rules

Preview deployments may:

- enable Lens Mode
- enable role switching
- use seeded test data
- use QA-only admin tooling

Do not:

- share production secrets with preview environments
- connect preview environments to unrestricted production admin tooling

## Destructive Actions

Destructive actions during impersonation or Lens Mode should:

- require explicit confirmation
- be logged
- preserve actor identity

Examples:

- deleting organizations
- billing changes
- ownership transfer
- role escalation
- destructive bulk operations

## Logging Requirements

Where practical, log:

- actor_user_id
- effective_user_id
- target organization
- action performed
- timestamp
- support reason or context

## Service Role Rules

Service-role keys are not user identities.

Do not:

- expose service-role keys to the browser
- use service-role authority to simulate users casually
- use service-role access to bypass tenant protections

## Validation Required

Verify:

- Lens Mode does not bypass authorization
- actor identity remains visible
- tenant boundaries remain enforced
- super_admin logic is server-side
- preview and production access differ appropriately
- destructive actions require confirmation where appropriate

## Failure Conditions

Classify as `P0 Critical`:

- silent impersonation in production
- service-role key exposed to client
- Lens Mode bypassing authorization
- cross-tenant access without enforcement

Classify as `P1 High`:

- missing actor tracking
- frontend-only admin enforcement
- unrestricted production Lens Mode
- weak admin logging

## Final Standard

Lens Mode is a build and QA tool.

Production authority must remain:

- explicit
- constrained
- reviewable
- auditable
