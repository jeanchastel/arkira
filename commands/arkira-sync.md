---
description: Check or apply Arkira engineering-standards drift in the current repo.
---

# /arkira-sync

Run a merge-aware sync of the Arkira engineering-standards files in the current
repository. The sync classifies every standards file into one of two tiers,
detects drift against an embedded sentinel or per-file baseline SHA, and
preserves local edits where the design says it should. It never commits,
pushes, or merges. On apply, it also verifies that GitHub native auto-merge
is enabled for the target repository.

See `governance/sync-standard.md` for the full policy, and
`docs/specs/2026-05-23-arkira-sync-merge.md` for the design.

## Behavior

- `/arkira-sync` (no arguments): read-only drift report. Lists every standards
  file as one of `clean`, `drifted`, `local-drift`, `conflict`, `missing`,
  `update-clean`, plus a CLI version freshness table. No prompts. No writes.
- `/arkira-sync --apply`: apply the safe updates. In `AGENTS.md`, rewrites
  canonical blocks marked with `<!-- ARKIRA:MANAGED START id=... -->` sentinels
  and prompts on drifted blocks (`keep | replace | abort`). `CLAUDE.md` and
  `CODEX.md` are exact pointer-only overlays. On first migration, genuine local
  content from either legacy role manual is moved into the user-owned area of
  `AGENTS.md`; superseded pristine harness role blocks are removed. For **Tier
  B** files (`workflows/*`, `scripts/*`,
  CI, issue templates, etc.), copies pristine updates automatically and
  **skips** local-drift / conflict files unless `--force-pristine` is set.
  It also removes only the exact retired Arkira `ggshield` commands and managed dash-guard block
  from the pre-commit and pre-push hooks in the repository's common Git directory,
  which are the hooks Git runs for the main work tree and every linked
  worktree. A configured `core.hooksPath` is never followed. Other hook
  content and modes are preserved. Dry-run reports this migration without
  writing.
- `/arkira-sync --apply --force-pristine`: same as `--apply`, plus prompts to
  overwrite locally-drifted or conflicting Tier B files.
- `/arkira-sync --apply --yes`: auto-answer `replace` to every prompt. Use only
  for non-interactive runs; this WILL overwrite local edits without review.

## Steps

1. Resolve the target repo root:
   `git rev-parse --show-toplevel`. If this fails, tell the user the current
   directory is not inside a git repo and stop.

2. Run the read-only drift check:
   `bash "${CLAUDE_PLUGIN_ROOT}/ai-engineering/bootstrap/check-ai-engineering-standards.sh" <repo-root>`
   Show the full output. It lists every standards file with its drift class.
   The script is read-only.

3. Report CLI version freshness and vendored freshness (read-only):
   `bash "${CLAUDE_PLUGIN_ROOT}/hooks/cli-freshness-check.sh" --report`
   Show the table. It lists each tracked CLI with its installed version, latest
   version, and gap class (current, safe, major, absent, unknown). This path is
   report-only. CLI updates are never run during SessionStart.

   Report vendored component freshness (read-only):
   `bash "${CLAUDE_PLUGIN_ROOT}/hooks/vendored-freshness-check.sh" --report`
   Surface the `vendored-freshness-check.sh --report` output under a
   **Vendored components** heading alongside the CLI and standards drift
   reports. Sync detects drift only and never writes vendored skill files.

4. If the user did not pass `--apply`, stop here. Summarize the drift and tell
   the user to re-run with `--apply` to update.

5. If the user passed `--apply`, first run the updater in dry-run mode:
   `bash "${CLAUDE_PLUGIN_ROOT}/ai-engineering/bootstrap/update-ai-engineering-standards.sh" <repo-root>`
   Show what WOULD CREATE, WOULD UPDATE, WOULD PROMPT, or WOULD SKIP.

6. Ask the user to confirm before applying. The repo's `AGENTS.md` requires
   explicit approval before file changes. If the user passed `--yes`, skip the
   confirmation but make sure they understand `--yes` auto-replaces every drift.

7. On confirmation, apply:
   `bash "${CLAUDE_PLUGIN_ROOT}/ai-engineering/bootstrap/update-ai-engineering-standards.sh" --apply [--force-pristine] [--yes] <repo-root>`
   The script writes a `.arkira/sync-state.json` baseline registry and prints
   the resulting `git diff --stat`. On drifted `AGENTS.md` blocks (and, with
   `--force-pristine`, drifted Tier B files), it prompts `keep | replace | abort`
   per item unless `--yes` is set.

8. Enable native GitHub auto-merge after the file transaction. Resolve the
   GitHub repository with `gh repo view --json nameWithOwner --jq .nameWithOwner`.
   Select the `standards` preset only when the target is the standards
   repository; use `product` otherwise. Run:
   `bash "${CLAUDE_PLUGIN_ROOT}/ai-engineering/scripts/set-branch-protection.sh" --repo <owner/name> --preset <standards|product> --apply`.
   Show its read-back. If `gh` is unavailable, unauthenticated, forbidden, or
   the read-back is false, report the blocked automatic-delivery setup and stop.
   Do not create, publish, or merge a candidate from sync.

9. Review the diff, then stage the intended candidate and run
   `candidate-gate.sh certify`. After exact-tree validation and tier-required
   review pass, complete it through `complete-candidate.sh --branch
   arkira/<workflow>-<unit> --message <message>`. The helper commits, creates
   the PR, and arms GitHub native squash auto-merge. A changed head, failed
   check, conflict, or permission failure leaves the PR open and is reported.

## Notes

- Content **outside** `ARKIRA:MANAGED` sentinels in `AGENTS.md` is sacred. The
  two role overlays are the deliberate exception: they are pointer-only, so a
  legacy overlay is canonicalized as a whole and every noncanonical fragment is
  first preserved in the user-owned area of `AGENTS.md`.
- The baseline registry at `.arkira/sync-state.json` is per-target-repo and is
  written only on `--apply`. A read-only check never writes.
- CLI version handling is report-only. Sync and SessionStart never invoke
  `npm i -g` or any other CLI installer.
