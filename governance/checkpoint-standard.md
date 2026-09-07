# Checkpoint Standard

A checkpoint is a small auto-memory file that lets a session be cleared and later
resumed. Each checkpoint has a deterministic Facts block (git state) and a Resume
note (what is in progress and what comes next). Checkpoints live in the
per-repo auto-memory directory under `checkpoints/`, with a rolling pointer
`project_last_checkpoint.md` indexed in `MEMORY.md`. To resume after a clear,
read the latest checkpoint.

Checkpoints are recovery backups. They do not replace the semantic, provider-neutral
handoff required by [session-segmentation-standard.md](./session-segmentation-standard.md).
Use `scripts/session-handoff.sh` at workflow boundaries. Keep interval checkpoints
for best-effort recovery inside long Claude Code sessions.

## Triggers

There are three triggers, all writing through `hooks/lib/checkpoint-lib.sh`:

1. Merge. `hooks/checkpoint-on-merge.sh` fires after `gh pr merge` or `git merge`
   and is always on. It records the merge facts and asks Claude to append a
   resume note.
2. Time interval. `hooks/time-checkpoint.sh` is a `Stop` hook gated by the
   `time_checkpoint` switch (default off). Once the configured interval has
   elapsed since the last checkpoint, it writes a facts-only checkpoint and exits
   silently. It does not block the stop or demand a resume note, so it never
   disrupts a session.
3. Manual. The `/checkpoint` command writes one on demand, with an optional note,
   and Claude appends a resume note. It works regardless of the switch.

## No wall-clock cron

Claude Code plugins have no timer trigger; hooks fire on events. The interval
checkpoint is therefore event-anchored: it is evaluated on each `Stop` and acts
only once the interval has passed, the same throttle pattern as
`cli-freshness-check.sh`. It fires while you are working, not during idle time.
A true OS cron was rejected: it would run outside a session, could record only
facts with no resume note, and would add platform-specific install surface.

## Configuration

- Enable interval checkpoints: set the `time_checkpoint` switch via `/arkira-init`.
- Interval: `.arkira/config.json` `checkpoint.interval_minutes`, or the
  `ARKIRA_TIME_CHECKPOINT_MINUTES` environment variable. Default 120 minutes.

## Storage and privacy

Checkpoints are written to auto-memory, which is not tracked in git. There is
nothing to commit. A future switch could mirror a short entry to a tracked
`docs/CHECKPOINT.md` for committed history; that is not built today.
