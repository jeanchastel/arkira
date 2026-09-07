# TEMPLATES

Reusable repository templates, documentation templates, and operational scaffolding.

## Claude Code noise controls

- `claude-settings.baseline.json`: the supported Claude Code control. `/arkira-init`
  merges these `permissions.deny` rules into `~/.claude/settings.json` without
  removing existing rules. They deny matching paths to built-in Read and are
  applied on a best-effort basis to Grep and Glob. The baseline also sets
  `CLAUDE_CODE_GLOB_NO_IGNORE=false`, which makes the Glob tool respect
  `.gitignore`.
- `.claudeignore`: compatibility-only input for editors or older integrations that
  explicitly consume it. Claude Code does not read `.claudeignore`, so this file
  is not a security or context-exclusion boundary.

`CLAUDE_CODE_GLOB_NO_IGNORE=false` affects only Claude Code's Glob tool. It does
not change Grep, Read, shell commands such as `find` or `ls`, or `@` file
autocomplete. The `permissions.deny` rules are therefore the supported
built-in-tool control for Arkira-generated chat noise, not a filesystem security
boundary. Read deny rules do not constrain Bash subprocesses; filesystem
sandboxing is a separate boundary.

References: [Claude Code permissions](https://code.claude.com/docs/en/permissions),
[settings](https://code.claude.com/docs/en/settings), and
[environment variables](https://code.claude.com/docs/en/env-vars).
