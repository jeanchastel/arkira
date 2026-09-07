---
description: Report that write-enabled re-vendoring is disabled for this release.
argument-hint: "[name]"
---

# /arkira-revendor

Write-enabled re-vendoring is disabled for this release. This command must not
change files, caches, Git state, branches, the index, commits, remotes, or pull
requests.

## Steps

1. Do not invoke any write preparation path.
2. Tell the user: `Re-vendoring is disabled for this release. Use the vendored
   freshness detect-only report for review.`
3. If the user needs current drift details, run only
   `bash "${CLAUDE_PLUGIN_ROOT}/hooks/vendored-freshness-check.sh" --report`.
