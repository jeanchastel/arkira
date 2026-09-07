#!/usr/bin/env bash
# Claude host adapter for provider-neutral session handoff notices.
# Healthy paths are silent. Every failure exits zero so the hook never blocks.
set -uo pipefail

plugin_root=${CLAUDE_PLUGIN_ROOT:-}
[ -n "$plugin_root" ] || exit 0
runtime="$plugin_root/ai-engineering/scripts/session-handoff.sh"
json_lib="$plugin_root/hooks/lib/json-lib.sh"
[ -f "$runtime" ] && [ ! -L "$runtime" ] && [ -f "$json_lib" ] || exit 0

# shellcheck source=hooks/lib/json-lib.sh
. "$json_lib"

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0
fields="$(arkira_payload_fields "$payload" hook_event_name cwd session_id)"
event="$(printf '%s\n' "$fields" | sed -n '1p')"
cwd="$(printf '%s\n' "$fields" | sed -n '2p')"
session_id="$(printf '%s\n' "$fields" | sed -n '3p')"
[ -n "$cwd" ] || cwd=${CLAUDE_PROJECT_DIR:-$PWD}
[ -n "$session_id" ] || exit 0
git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

case "$event" in
  SessionStart) notice_event=session-start ;;
  UserPromptSubmit) notice_event=user-prompt ;;
  *) exit 0 ;;
esac

ARKIRA_SESSION_REPO="$cwd" bash "$runtime" notice \
  --event "$notice_event" --session-id "$session_id" 2>/dev/null || true
exit 0
