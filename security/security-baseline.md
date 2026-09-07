# Security Baseline

## Purpose

Define the minimum acceptable security expectations for Arkira-governed repositories.

## Scope

Applies to:

- frontend systems
- backend systems
- APIs
- databases
- deployment environments
- AI-assisted software repositories

## Secrets

### Do Not

- commit secrets
- expose server secrets to client bundles
- hardcode API keys
- log credentials
- store production secrets in test files

### Requirements

Environment variables should:

- be documented
- be scoped appropriately
- be separated by environment
- avoid unnecessary client exposure

## Authentication

Authentication must:

- validate server-side
- fail securely
- avoid trust in client state alone
- enforce explicit authorization checks

## Authorization

Sensitive systems should verify:

- user identity
- role permissions
- resource ownership where applicable

Missing authorization is considered a `P0 Critical` issue.

## Input Validation

All external input should be validated.

Never trust:

- request bodies
- query parameters
- uploaded files
- client-generated state

## Logging

Logs must not expose:

- credentials
- access tokens
- session identifiers
- private user data
- database secrets

## Deployment Security

Production deployments should:

- use protected environments
- separate preview and production secrets
- require PR-based deployment flow
- avoid direct production experimentation

## Dependency Hygiene

Dependencies should:

- be actively maintained
- be minimized where practical
- avoid unnecessary overlap
- be reviewed periodically for vulnerabilities

## AI-Assisted Development Rules

AI-generated code requires:

- explicit security review
- auth verification
- deployment review
- secret exposure review
- validation scrutiny

Do not assume generated code is secure.

## Validation Required

Security-sensitive changes should verify:

- auth behavior
- authorization enforcement
- environment handling
- client/server boundaries
- secret exposure risk

## Severity Language

Use the canonical P0 to P3 labels from the Severity Classes block in `ai-engineering/root/AGENTS.md`.

## Final Standard

Security posture should prioritize:

- operational safety
- explicit validation
- predictable enforcement
- low exposure risk

Convenience is not a security strategy.
