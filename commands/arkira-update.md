---
description: Focused re-prompt for Arkira switches added since the last /arkira-init run.
---

# /arkira-update

Detect switches in `ai-engineering/bootstrap/switches.json` that were introduced after the user's current `standards_version`, prompt only for those, and write the result. Reuses `arkira-write-config.sh` under the hood.

## Behavior

- `/arkira-update` (no arguments): run the focused re-prompt.
- `/arkira-update --dry-run`: same flow but stop before applying.

## Steps

1. Resolve repo root via `git rev-parse --show-toplevel`. If absent, pass `--no-repo` to the write script and operate on the user config only.

2. Read the current user-level config:

   ```bash
   jq . "${ARKIRA_INIT_HOME:-$HOME}/.arkira/config.json"
   ```

   If this fails, tell the user `/arkira-init` must run first, then stop.

3. Compute the new-switches list:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/ai-engineering/bootstrap/arkira-update-detect.sh" \
     "${ARKIRA_INIT_HOME:-$HOME}/.arkira/config.json" \
     "${CLAUDE_PLUGIN_ROOT}/ai-engineering/bootstrap/switches.json"
   ```

   Each line is one switch id.

4. If the list is empty, print `Arkira is up to date at version <standards_version>.` and stop.

5. If `update_mode == "auto"` in the user config: skip the Q&A. Build the decisions JSON using each new switch's `default` value plus the existing config values for old switches. Bump `standards_version` to the plugin's `VERSION.md`. Continue at step 7.

6. If `update_mode == "manual"`: for each new switch id, read its entry from `switches.json` and ask the user one question. Default highlighted. Merge answers with the existing config to build the decisions JSON. Bump `standards_version`.

7. Dry-run to compute diff, show output, ask for confirmation. Identical to `/arkira-init` steps 7 through 11. Skip the disclosure card.

## Notes

- This command never adds back switches the user deleted from their config. It only acts on switches whose `introduced_in` is strictly greater than the current `standards_version`.
- After a successful apply, the next SessionStart will see matching versions and stay silent.
