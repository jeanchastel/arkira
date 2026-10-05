# Sync Standard

Arkira product repositories use the verified central harness. The public
repository `jeanchastel/arkira` is the sanctioned stable control channel.
`harness.channel: stable` and `harness.repository: jeanchastel/arkira` select
it. Runtime resolution verifies the exported payload and uses the immutable
harness store. New sessions adopt stable; an active goal keeps its bound
snapshot. Offline work requires a verified cache. Publication requires online
verification.

`arkira context <repo>` returns the central instructions. SessionStart never
fetches, installs, copies, or rewrites standards. `/arkira-sync` reports the
central route and previews migration for a repository that has not adopted it.
There is no vendored-file sync apply path.

## Migration

`arkira migrate <repo>` previews owned changes without writing.
`arkira migrate <repo> --apply` requires an online verified public release and
applies the complete plan through contained filesystem operations. The
repository must be clean. Ownership drift, unsafe paths, and retained callers
of retired controls abort migration. Recovery receipts remain private outside
the consumer. `arkira rollback-migration <repo> <receipt>` refuses intervening
target edits. An unmigrated repository remains on its existing vendored copy
until migration is explicitly applied.

The ordered migration inventory is `ai-engineering/bootstrap/sync-checks.json`.
Each row records source, target, profile, and scope. `migration-preflight.mjs`
uses it to identify owned installed files. `scope: central` records canonical
inputs that were never copied. Profile filters select `app`, `static-web`, or
all profiles with `*`. The inventory is data, not an executor.

Migration preserves project-owned context, rejects unknown modified controls,
and replaces owned CI with the central caller. The central caller pins the
verified release commit in first-party workflow and Action references.
`@stable` references are accepted in the source template. Third-party actions
remain SHA-pinned. The reusable workflow checks out its own
`job.workflow_sha` separately from the product and retains mandatory product
validation. Consumer configuration cannot select a public commit.

A product may pass `validation_fixture_environment` to central `validate.yml`
for inert build-time placeholders. The central workflow retains that input.

## Product release inventory

The standards repo's `scripts/test-suites.tsv` is the harness's internal test
inventory and is never copied into product repos. Historical product sync mapped
`ai-engineering/gates/product-test-suites.tsv` to the product repo's
`scripts/test-suites.tsv`. That inventory has one required entry which calls
`scripts/run-product-release-gate.sh`.

The product release gate does not install dependencies. The workflow resolves
one trusted base commit from the pull request base or the pre-push main commit
and passes it as `ARKIRA_TRUSTED_BASE_SHA` to both release helpers. Repository
class comes only from that base's profile and package tree. Candidate changes
cannot reclassify a package, static-web, or non-package repository.

The helpers follow this closed contract:

1. Every package repo has a committed regular `package.json`, exactly one
   committed supported lockfile, an exact matching `packageManager` name and
   version pin, and non-empty `lint`, `typecheck`, `test`, and `build` scripts.
2. The installer always performs the lockfile-specific immutable install. The
   release gate always runs all four package scripts in order.
3. A committed regular `scripts/project-release-gate.sh` adds product-specific
   checks after the four package checks. It never replaces dependency setup or
   the mandatory package checks.
4. Static-web and non-package repos must provide the explicit project gate.
   Static-web repos that also have a package manifest satisfy both contracts.
5. A committed regular `.arkira/ci-build-env` (`KEY=VALUE` lines, `#` comments,
   blank lines ignored) is exported before any release task or explicit
   project gate runs. It exists so a build that validates environment at
   module scope (for example a Next.js app that freezes `process.env` at
   import time) can be satisfied with placeholders. The file is committed and
   therefore world-readable to anyone who can read the repository: it must
   never carry a real credential, only an inert value that satisfies schema
   validation. A malformed line or an uncommitted file exits `77`. It loads
   before the harness's own `CI` and pnpm quarantine/verify exports, which
   always run after and win, so it cannot weaken those safety defaults.

An absent or ambiguous required gate exits `77`. The canonical runner records
that as a development skip and as a blocker for a required release suite.
The synced `validate` CI job installs dependencies separately through
`scripts/install-product-dependencies.sh`. That installer accepts only a
committed regular `package.json` and exactly one committed regular npm, pnpm,
or Yarn lockfile. npm must match the installed version. pnpm and Yarn run
through Corepack and must resolve to the exact `packageManager` version. There
is no lockfile or package-manager fallback. The CI job then invokes the same
canonical product inventory with `scripts/run-all-tests.sh --mode release`.
The `validate` workflow runs on pull requests to `main` only. Release mode
captures the clean candidate before any suite and fails if HEAD or the worktree
changes during a suite.

Only one unfiltered canonical gate may own a repository at a time. Every suite
runs in a separate process group so a gate termination or suite timeout stops
the complete descendant tree. The per-suite timeout defaults to 900 seconds and
may be changed with a positive integer `ARKIRA_SUITE_TIMEOUT_SECONDS` value.
Filtered development runs do not take the repository-wide full-gate lock.

## Post-merge delivery

The canonical dogfood post-merge workflow runs only after a `main` push and only when the repository sets
`ARKIRA_POST_MERGE_DELIVERY_ENABLED=true`. It has two explicit delivery modes:

1. `repository-script` is the default. The repository must provide an executable
   `scripts/deploy-production.sh`, which receives the merged SHA as its sole argument.
2. `provider-managed` requires `ARKIRA_PROVIDER_STATUS_CONTEXT`. The workflow polls that exact
   GitHub commit-status context and records success only after the provider reports success.

`POST_MERGE_WEBHOOK_URL` and `POST_MERGE_WEBHOOK_SECRET` are required for either mode. The callback
is HMAC-signed over its exact JSON payload, uses `<repository>:<sha>` as its idempotency key, and
reports `deployment.status` as either `succeeded` or `failed`. A failed delivery still sends its
failure callback before the workflow remains failed. Each callback request has bounded connection
and total request time and retries at most three times.

## Installed distribution

Installed harness commands capture a private, content-addressed snapshot and
verify its manifest. Resolution uses the active goal binding first, then an
explicit verified rollback pin, then a fresh installed-root capture. A legacy
repository binding is a fallback only when no installed source is available.
The default is `harness.channel: installed`. Rollback uses `harness.channel:
pinned` with the exact `harness.pin` and `harness.digest` of a verified
snapshot. Installation and update remain native platform operations.

See `ai-engineering/distribution/publishing.md` for public release rules and
`commands/arkira-sync.md` for the operator command.

## Legacy managed context

Migration recognizes historical `AGENTS.md` managed blocks with this format:

```markdown
<!-- ARKIRA:MANAGED START id=role-and-purpose v=2 sha=abc123… -->
canonical content
<!-- ARKIRA:MANAGED END id=role-and-purpose -->
```

`sha` is SHA-256 of the body after trimming leading and trailing blank lines.
Unknown or modified blocks remain conflicts; migration does not discard them.
The historical `.arkira/sync-state.json` registry is read as ownership evidence
and removed only in an accepted migration transaction. Product-owned
`.arkira/risk-paths.json` remains outside that transaction.
