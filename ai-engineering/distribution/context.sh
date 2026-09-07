#!/usr/bin/env bash
set -euo pipefail
repo="${1:?target repository is required}"
root="${ARKIRA_HARNESS_ROOT:?verified harness root is required}"
session="${ARKIRA_RELEASE_SESSION:?release session is required}"
printf 'Arkira release: %s (%s)\nRepository: %s\n' \
  "$ARKIRA_HARNESS_VERSION" "$ARKIRA_HARNESS_SHA" "$repo"
printf 'Session: %s\nHarness root: %s\n\n' "$session" "$root"
printf 'For every subsequent Arkira command in this session, use: arkira --session %s\n' "$session"
printf 'Pass the same session to delegated work. Do not start a new context during an active unit.\n'
printf 'Project-owned instructions in AGENTS.md and child context files remain in force.\n'
printf 'Shared workflow references resolve under %s/ai-engineering/workflows/.\n' "$root"
printf 'Shared governance references resolve under %s/governance/.\n' "$root"
printf 'Shared runtime references resolve under %s/ai-engineering/runtime/.\n' "$root"
printf 'Shared script references resolve under %s/ai-engineering/scripts/.\n' "$root"
printf 'Product-specific checks and deployment scripts remain in the product repository.\n'
printf 'Read the relevant shared workflow from those paths before acting.\n\n'
cat "$root/ai-engineering/root/AGENTS.md"
