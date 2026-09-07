---
description: First-run setup wizard for the Arkira standards plugin. Collects security and tooling switch preferences, then writes them to disk.
---

# /arkira-init

Run the Arkira standards onboarding wizard. Collect the user's choices on every switch in `ai-engineering/bootstrap/switches.json`, present a consolidated diff of pending writes, and apply on a single confirmation.

## Behavior

- `/arkira-init` (no arguments): run the interactive wizard.
- `/arkira-init --dry-run`: run the wizard but stop after presenting the diff. Touches no disk.

## Steps

1. Resolve the target repo root:
   `git rev-parse --show-toplevel`. If this fails, set `repo_root` to empty and remember to pass `--no-repo` to the write script later. Inform the user that only the user-level config will be written.

2. Read the switch inventory:
   `cat "${CLAUDE_PLUGIN_ROOT}/ai-engineering/bootstrap/switches.json"`. Parse the JSON.

3. Print the disclosure card:

   Arkira Labs Standards setup. CLI-first connectors (Supabase and Vercel CLIs preferred over MCP or REST). Security review defaults on. Local Gitleaks scanning is available only through an explicit command and is not an init switch. Drift checked, never silently applied (`/arkira-sync` surfaces drift, you apply changes through normal review). You can opt out of any switch below. Defaults are highlighted.

4. For each switch in `switches.json`, ask the user one question. Highlight the default. Collect the answer. Track answers in memory as a `{id: boolean}` map.

5. After all switches, ask the meta-questions:
   - `update_mode`: "How do you want updates handled?" with `manual` (recommended, nudge when new switches arrive) or `auto` (silently apply new defaults on plugin upgrade).
   - `apply_to_new_repos`: "Apply these settings automatically to every future repo, or prompt per repo?" with `yes` (auto) or `no` (per-repo).

6. Build the decisions JSON in memory using the `standards_version` from the plugin's `VERSION.md`:

   ```json
   {
     "schema_version": 1,
     "standards_version": "<plugin VERSION.md value>",
     "apply_to_new_repos": true,
     "update_mode": "manual",
     "switches": { "verbose_permissions": false, "cli_first_connectors": true }
   }
   ```

7. Dry-run the complete init transaction first to compute the diff:

   ```bash
   printf '%s' '<decisions JSON>' | \
     bash "${CLAUDE_PLUGIN_ROOT}/ai-engineering/bootstrap/arkira-apply-init.sh" \
       --repo-root "<repo_root>" --dry-run
   ```

   If step 1 found no repository, use `arkira-write-config.sh --no-repo
   --dry-run` instead because repo-local side effects do not apply. Show the full
   output to the user. The output includes a `PATCH` or `CONFIG-ONLY` line per
   switch and any `CONFLICT` lines where the user's existing
   `~/.claude/settings.json` already sets a key to a different value.

8. If the user invoked with `--dry-run`, stop here.

9. Ask for confirmation: `Apply these changes? [y/N]`.

10. On `y`, apply the same complete transaction:

    ```bash
    printf '%s' '<decisions JSON>' | \
      bash "${CLAUDE_PLUGIN_ROOT}/ai-engineering/bootstrap/arkira-apply-init.sh" \
        --repo-root "<repo_root>" --apply
    ```

    If step 1 found no repository, use `arkira-write-config.sh --no-repo
    --apply` instead.

    Show the output and a summary line like `Arkira configured for <repo_root>.`
    Then print one pointer line: `Optional tools available (each license-noted): see tooling/suggested-tools.md.`

11. On `N`, say `Aborted. No changes made.` and stop.

12. Do not run graph setup as a follow-up command. The apply helper stages Claude settings and Arkira
    configs before publication. The knowledge graph is built only after its
    prior directory is moved to a private rollback name. A failure restores
    every prior target and removes files or directories created by that
    invocation. The optional `code-review-graph` CLI is still a silent skip
    when it is absent; when present, its graph is part of the transaction.

## Notes

- The apply helper is the only complete repo init writer. Claude does the Q&A
  and displays the dry-run, but does not reproduce its graph command.
- `--dry-run` makes the wizard safe to demo without committing the user to anything.
- The script refuses to run if `~/.claude/settings.json` is malformed JSON; in that case the user must fix the file and re-run.
- The script merges `templates/claude-settings.baseline.json` into the user's
  existing Claude Code settings without removing existing deny rules. The
  supported `permissions.deny` entries deny built-in Read access to Arkira
  runtime state, diagnostics, caches, and proposal queues; Claude Code applies
  Read deny rules to Grep and Glob on a best-effort basis.
  `CLAUDE_CODE_GLOB_NO_IGNORE=false` makes only Glob respect `.gitignore`; it
  does not affect Grep, Read, shell commands, or `@` autocomplete.
- `.claudeignore` is compatibility-only. Claude Code does not consume it.
- Approved automation such as `/arkira-new` uses
  `${CLAUDE_PLUGIN_ROOT}/ai-engineering/bootstrap/arkira-apply-init.sh`. That
  non-interactive helper accepts a complete decisions payload and composes the
  config writer with the same graph side effect.
  Calling `arkira-write-config.sh` alone is config-only and is not a complete
  init flow.
