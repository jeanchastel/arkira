---
description: Write a checkpoint of the current session to auto-memory, with an optional note.
---

# /checkpoint

Write a resumable checkpoint of the current work to auto-memory now, regardless
of the `time_checkpoint` switch. Use it before clearing a long session, before a
risky change, or any time you want a labeled resume point.

This is a best-effort Claude recovery backup. At a semantic workflow boundary,
use the provider-neutral `scripts/session-handoff.sh` contract instead.

## Behavior

- `/checkpoint`: write a checkpoint with the current git facts.
- `/checkpoint <note>`: same, plus a short note recorded in the checkpoint, for
  example `/checkpoint before auth refactor`.

## Steps

1. Resolve the repo root: `git rev-parse --show-toplevel`. If this fails, tell
   the user the current directory is not inside a git repo and stop.

2. Write the checkpoint facts:
   `bash "${CLAUDE_PLUGIN_ROOT}/hooks/checkpoint-now.sh" "$ARGUMENTS"`
   The script prints the path of the checkpoint file it wrote. If it exits
   non-zero, show its message and stop.

3. Append a resume note to that file. Open the printed checkpoint file and
   replace the placeholder comment under `## Resume note` with: what is in
   progress conceptually, the current project state, and the next steps. Keep it
   to a few sentences.

4. Confirm to the user with the checkpoint path. Auto-memory is not tracked in
   git, so there is nothing to commit.

## Notes

- This command always writes a checkpoint. The `time_checkpoint` switch controls
  only the automatic interval checkpoints; it does not affect `/checkpoint`.
- To enable automatic interval checkpoints, set the `time_checkpoint` switch via
  `/arkira-init`. The interval defaults to 120 minutes and is configurable via
  `.arkira/config.json` `checkpoint.interval_minutes` or the
  `ARKIRA_TIME_CHECKPOINT_MINUTES` environment variable. See
  `governance/checkpoint-standard.md`.
