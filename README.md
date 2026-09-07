# Arkira

Shared engineering context, governed task execution, and reusable validation for
Claude Code and Codex. This repository is a generated release distribution.
Authoring history, fleet reports, and operator state are not included.

## Release contract

The protected `stable` tag selects the approved public release. New sessions
resolve it to an exact commit and verify every payload file before use. Active
sessions and goals retain their original snapshot. Local work may use an already
verified cached release offline; publication and new CI runs require online
verification. Major upgrades emit a one-time notice.

`release.json` records the private source commit, release version, and SHA-256
inventory. Transport from this repository authenticates the release; the
self-contained manifest detects file changes but is not a signature.

Product repositories retain project instructions, settings, product checks, and
deployment code. Shared implementation stays here. The reusable
`.github/workflows/validate.yml@stable` workflow runs documentation, type-only,
or mandatory product validation against the pull request's trusted base.

## Runtime

Requirements: Git, Node.js, Bash, jq, and the native agent client used for work.
Install the public distribution without private-source credentials:

```sh
git clone --branch stable --single-branch https://github.com/jeanchastel/arkira.git arkira
```

Add the checkout's `bin` directory to your PATH. The launcher resolves and verifies
the public release for opted-in consumers; ordinary updates do not rewrite consumer
files. Native plugin installation remains a separate operation in the agent client.
From the installed distribution, run:

```sh
bin/arkira context /path/to/product
bin/arkira --session <returned-session-id> task /path/to/product status
```

Use the returned session ID for subsequent commands and delegated work.
Do not download or execute harness scripts from an untrusted caller-supplied URL.
A failed verification blocks execution.

## Onboard or migrate a repository

Start with a clean committed repository. Preview, inspect the paths, then apply:

```sh
arkira migrate /path/to/product
arkira migrate /path/to/product --apply
arkira context /path/to/product
```

Apply requires online public verification before retiring any legacy control.
Project-owned instructions, preferences, product checks, and deployment files stay
in the product. Unknown ownership, drift, links, or retained callers of retired
controls block the whole migration. Review and merge the resulting product PR
through the existing acceptance gate; migration does not deploy the product.

The apply output names a private recovery receipt outside the product. To undo
the file changes before proceeding, use:

```sh
arkira rollback-migration /path/to/product /absolute/path/to/receipt.json
```

Rollback refuses intervening target edits. It does not rewrite Git history or move
public tags. Keep the receipt until the migration is accepted and recovery is no
longer needed; it contains original project file contents and must not be committed
or uploaded. Failed transactions retain recovery evidence for manual inspection.

Native SessionStart notices supply a session-specific context command. Run that
command before acting and retain its session ID for delegated work. The notice
itself performs no network access or installation changes.

P1. Existing required-check names must be verified on the first migration PR;
reusable-workflow check names may differ. Do not disable product checks to merge.

## Public and authoring boundaries

The exported governance and workflows are the shared instructions. Historical
authoring-spec links may refer to private design records; those records are not
installation dependencies. The public package never requires private fleet data.
Experimental high-assurance machinery remains unsupported as documented in its
workflow. The source-only publisher and fleet rollout reports are not distributed.

## Licensing

Arkira is MIT licensed. See LICENSE, THIRD_PARTY_NOTICES.md, and VENDORED.md.
