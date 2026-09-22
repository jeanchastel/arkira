# Arkira Orchestrator

Shared engineering context, governed task execution, and reusable CI validation for
Claude Code and Codex.

## TL;DR

Arkira Orchestrator is one versioned repository of shared rules, scripts, and CI. Product
repositories do not copy any of it. They call it at the protected `stable` tag, so every
product runs the same verified release and an upgrade is a tag move, not a sync.

You reach it through two surfaces:

- A local CLI. `arkira context <repo>` loads the shared instructions into your agent session
  and returns a session ID. `arkira task` and `arkira goal` run the work under those rules.
- A GitHub Actions caller. One small workflow in the product calls the shared `validate.yml`
  from the same release and publishes a single `validate` check on the pull request.

Both surfaces resolve `stable` to an exact commit and verify every payload file against a
SHA-256 inventory before anything runs. A failed verification stops the run.

The product keeps its own code, instructions, settings, product checks, and deployment
scripts. Arkira Orchestrator keeps the shared implementation, and none of it lands in the
product tree.

First day on a repository:

```sh
arkira migrate /path/to/product           # preview the exact file changes
arkira migrate /path/to/product --apply   # install the caller, retire legacy controls
arkira context /path/to/product           # start a session, read the shared context
```

Every day after that: run `arkira context`, keep the session ID, and drive work with
`arkira task` or `arkira goal`. CI validates the pull request from the same release.

This repository is a generated release distribution. Authoring history, fleet reports,
and operator state stay private and are not published here.

## Requirements

Git, Bash, jq, Node.js 24, and the agent client you work in.

## Install

```sh
git clone --branch stable --single-branch https://github.com/jeanchastel/arkira.git arkira
```

Add the checkout's `bin` directory to your PATH. The launcher resolves and verifies the
public release before it runs anything. A failed verification blocks execution. Installing
the plugin inside an agent client is a separate step.

Never download or run harness scripts from a URL supplied by a caller.

## Start a session

```sh
arkira context /path/to/product
```

The command prints the release version, the resolved harness root, and a session ID. Pass
that ID to every later command in the same unit of work:

```sh
arkira --session <session-id> task /path/to/product status
```

Delegated work uses the same session. Do not open a new context in the middle of a unit.

## Onboard a repository

Start from a clean committed repository. Preview first, read the listed paths, then apply:

```sh
arkira migrate /path/to/product
arkira migrate /path/to/product --apply
arkira context /path/to/product
```

Apply requires online verification of the public release before it retires any legacy
control. Unknown file ownership, drift, stale links, or a retained caller of a retired
control blocks the whole migration.

Migration installs two workflows in the product:

- `.github/workflows/arkira-ci.yml`, the thin caller that runs validation on pull requests.
- `.github/workflows/arkira-release-candidate.yml`, a path filtered cache warm on trusted main.

Review and merge the resulting pull request through the existing acceptance gate. Migration
does not deploy the product.

Verify the required check names on the first migration pull request. The caller publishes a
check named `validate`. The auto merge guard publishes `arkira-delivery-authorization`. Do
not disable product checks to merge.

### Undo a migration

The apply output names a private recovery receipt written outside the product:

```sh
arkira rollback-migration /path/to/product /absolute/path/to/receipt.json
```

Rollback refuses to run if the target changed after apply. It does not rewrite Git history
and does not move public tags. The receipt contains original product file contents, so never
commit or upload it. Keep it until you accept the migration.

## Commands

- `arkira task <repo> dispatch|status|recover|watch` runs and tracks a single unit of work.
- `arkira task <repo> checks [<pr>] [--watch]` reports pull request check state.
- `arkira goal|swarm|preview <repo> <command>` runs the larger delivery operators.
- `arkira gate <repo> <command>` runs the candidate gate against the repository.
- `arkira dashboard [--root <path>]` opens the portfolio dashboard.
- `arkira secret-scan working-tree|history` scans for committed secrets.
- `arkira bug-report create <repo> --from-candidate-gate` bundles a gate failure.
- `arkira bug-report submit <bundle> --destination <configured-destination>` sends the bundle.
- `arkira harness capture|resolve|gc` manages the local release store.

## Validation in CI

The caller invokes `jeanchastel/arkira/.github/workflows/validate.yml@stable`. Each job that
touches product code checks out the pinned harness commit and verifies the release first.

A plan job resolves the trusted base and classifies the change into one shape:

- `report-only` for documentation. It runs the documentation gate and nothing else.
- `type-only` for changes that need type checks but no behavior run.
- `behavioral` for everything else.

A behavioral change runs in one of two modes. Split mode needs a trusted `.arkira/ci.json`
that is byte identical in the base and the candidate. Any other state falls back to legacy
validation, which runs the full release inventory for a Dependabot pull request.

In split mode:

- The fast job installs immutable dependencies and builds the candidate once.
- A Dependabot pull request also runs the fast checks there, because no local certification covers it.
- That job uploads the build as an artifact keyed to the exact candidate commit.
- The database job runs only when changed files match a declared risk path.
- Four browser shards download that exact build and run isolated Playwright checks.

`.arkira/ci.json` uses `schema_version` 1 and declares `build_artifact`, `database`, and
`browser`. The database contract names the provider, the package script, and the risk paths.
The browser contract fixes four shards.

## Release contract

The protected `stable` tag selects the approved public release. A new session resolves that
tag to an exact commit and verifies every payload file before use. An active session or goal
keeps its original snapshot for its whole life.

`release.json` records the private source commit, the release version, and a SHA-256
inventory. Transport from this repository authenticates the release. The manifest detects
changed files but is not a signature.

Local work can use an already verified cached release offline. Publication and new CI runs
require online verification. A major upgrade prints a one time notice.

## What stays in the product

Product repositories keep their own instructions, settings, product checks, and deployment
code. Shared implementation stays here.

## Public and authoring boundaries

The exported governance and workflows are the shared instructions. Some authoring links
point at private design records. Those records are not installation dependencies, and the
public package never requires private fleet data. The source only publisher and the fleet
rollout reports are not distributed.

## Licensing

Arkira Orchestrator is MIT licensed. See LICENSE, THIRD_PARTY_NOTICES.md, and VENDORED.md.
