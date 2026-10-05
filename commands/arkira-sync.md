---
description: Preview Arkira central migration for the current repository.
---

# /arkira-sync

Resolve the current repository with `git rev-parse --show-toplevel`.
Read its `.arkira/config.json` and report the harness channel.

For a repository on `harness.channel: stable` with
`harness.repository: jeanchastel/arkira`, run `bin/arkira context <repo-root>`
and read the verified central instructions. There are no copied standards to sync.
CLI and vendored component freshness reports remain read-only.

For a repository that is not on the central route, run
`bin/arkira migrate <repo-root>` to preview the owned changes. Show conflicts
and the migration plan. Migration requires a clean repository and exact
ownership of any retired vendored controls. After review and authorization,
`bin/arkira migrate <repo-root> --apply` performs the migration to stable.
Do not invoke the retired vendored-file sync scripts.

`/arkira-sync --apply` does not apply copied standards. Direct the operator to
`arkira migrate <repo-root> --apply` after reviewing its preview. Migration
never commits, pushes, or merges the result.
