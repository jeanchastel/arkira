#!/usr/bin/env bash
set -uo pipefail

role_manage_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=ai-engineering/runtime/role-runtime.sh
. "$role_manage_dir/role-runtime.sh"

role_manage_usage() {
  printf 'usage: role-manage.sh status|doctor|set|test|reset|repair\n' >&2
  return 2
}

role_manage_current_is_invalid() {
  local repo=$1 config="$1/.arkira/roles.json"
  [[ -e "$config" || -L "$config" ]] || return 1
  arkira_validate_role_candidate "$config" >/dev/null 2>&1 || return 0
  return 1
}

role_manage_render_base() {
  local repo=$1 config="$1/.arkira/roles.json"
  if [[ -f "$config" && ! -L "$config" ]] && arkira_validate_role_candidate "$config"; then
    jq -c . "$config"
  else
    arkira_mission_default_json
  fi
}

role_manage_effort_summary() {
  local role=$1 adapter=$2 capability effort summary=""
  while IFS= read -r capability; do
    effort="$(arkira_resolve_effort "$adapter" "$capability" 2>/dev/null || true)"
    [[ -n "$effort" ]] || effort=not_configured
    [[ -n "$summary" ]] && summary="$summary,"
    summary="$summary$capability:$effort"
  done < <(arkira_role_required_capabilities "$role")
  printf '%s' "$summary"
}

role_manage_rtk_status() {
  local binary version settings hook_commands probe gain saved=unavailable
  binary="$(command -v rtk 2>/dev/null || true)"
  if [[ -z "$binary" || ! -x "$binary" ]]; then
    # RTK is operator-global and optional. Absence is a reported state, not a harness failure.
    printf 'RTK\tpath=unavailable\tversion=unavailable\thook=unavailable\tsaved=unavailable\toptional=yes\n'
    return 0
  fi
  version="$(rtk --version 2>/dev/null | sed -n '1s/^rtk[[:space:]]*//p')"
  [[ -n "$version" ]] || {
    printf 'ERROR: the PATH rtk is not Rust Token Killer\n' >&2
    return 13
  }
  probe="$(printf '%s\n' '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
    | rtk hook claude 2>/dev/null || true)"
  printf '%s' "$probe" | jq -e \
    '.hookSpecificOutput.updatedInput.command == "rtk git status"' >/dev/null 2>&1 || {
    printf 'ERROR: RTK Claude hook did not rewrite the health probe\n' >&2
    return 13
  }
  settings="${ARKIRA_CLAUDE_SETTINGS:-${HOME}/.claude/settings.json}"
  if [[ -e "$settings" || -L "$settings" ]]; then
    [[ -f "$settings" && ! -L "$settings" ]] && jq -e . "$settings" >/dev/null 2>&1 || {
      printf 'ERROR: Claude settings are missing, unsafe, or invalid: %s\n' "$settings" >&2
      return 16
    }
    hook_commands="$(jq -r '
      [.hooks.PreToolUse[]? | select((.matcher // "") == "Bash") | .hooks[]? |
       select(.type == "command") | .command | select(type == "string" and test("rtk.*hook claude"))] |
      .[]
    ' "$settings")"
    if [[ -n "$hook_commands" && "$hook_commands" != "rtk hook claude" ]]; then
      printf 'ERROR: Claude Bash hook must resolve RTK through PATH as: rtk hook claude\n' >&2
      return 16
    fi
    if [[ -z "$hook_commands" ]]; then
      printf 'RTK\tpath=%s\tversion=%s\thook=not_configured\tsaved=%s\n' \
        "$binary" "$version" "$saved"
      return 0
    fi
  else
    printf 'RTK\tpath=%s\tversion=%s\thook=not_configured\tsaved=%s\n' \
      "$binary" "$version" "$saved"
    return 0
  fi
  gain="$(rtk gain 2>/dev/null || true)"
  saved="$(printf '%s\n' "$gain" | sed -n 's/^[[:space:]]*Tokens saved:[[:space:]]*//p' | head -1)"
  [[ -n "$saved" ]] || saved=unavailable
  printf 'RTK\tpath=%s\tversion=%s\thook=ready\tsaved=%s\n' "$binary" "$version" "$saved"
}

role_manage_status() {
  local repo config role provider model adapter auth=ok rc=0 instructions efforts
  repo="$(arkira_repo_root)" || return 16
  config="$repo/.arkira/roles.json"
  if [[ -e "$config" || -L "$config" ]]; then
    if ! arkira_validate_role_candidate "$config"; then
      printf 'ERROR: %s\n' "$(arkira_role_config_error "$config")" >&2
      return 16
    fi
  fi
  for role in planner executor verifier; do
    provider="$(arkira_resolve_role "$role" provider)" || return $?
    model="$(arkira_resolve_role "$role" model)" || return $?
    auth=ok
    if [[ "$provider" != host-session ]]; then
      adapter="$(arkira_adapter_file "$provider")" || return 11
      if ! arkira_auth_preflight "$adapter"; then
        auth=failed
        instructions="$(jq -r '.authentication_instructions // "complete provider login"' "$adapter")"
        printf 'AUTH: %s: %s\n' "$provider" "$instructions" >&2
        rc=10
      fi
      efforts="$(role_manage_effort_summary "$role" "$adapter")"
    else
      efforts=host-session
    fi
    printf '%s\tprovider=%s\tmodel=%s\teffort=%s\tauth=%s\n' \
      "$role" "$provider" "${model:-provider-default}" "$efforts" "$auth"
  done
  role_manage_rtk_status || rc=$?
  return "$rc"
}

# The reflection hook dispatches the Verifier as a real provider call. host-session cannot be
# dispatched, so that combination is a configuration mismatch, not a runtime surprise.
role_manage_reflection_switch_on() {
  local repo=$1 config
  for config in "$repo/.arkira/config.json" "${ARKIRA_ROLE_HOME:-$HOME}/.arkira/config.json"; do
    [[ -f "$config" && ! -L "$config" ]] || continue
    [[ "$(jq -r '.switches.self_improving_claude_md // false' "$config" 2>/dev/null)" == true ]]
    return
  done
  return 1
}

role_manage_doctor() {
  local adapter role_schema="$ARKIRA_AI_ENGINEERING_DIR/bootstrap/roles-schema.json" repo config rc=0
  for adapter in "$(arkira_adapter_dir)"/*.json; do
    [[ "$(basename -- "$adapter")" == schema.json ]] && continue
    arkira_validate_adapter_file "$adapter" || {
      printf 'ERROR: invalid adapter %s\n' "$adapter" >&2
      rc=11
    }
  done
  repo="$(arkira_repo_root)" || return 16
  config="$repo/.arkira/roles.json"
  if [[ -f "$config" && ! -L "$config" ]]; then
    arkira_validate_json_schema "$role_schema" "$config" || {
      printf 'ERROR: roles.json does not match roles-schema.json\n' >&2
      rc=16
    }
  fi
  if role_manage_reflection_switch_on "$repo" &&
    [[ "$(arkira_resolve_role verifier provider 2>/dev/null)" == host-session ]]; then
    printf 'ERROR: self_improving_claude_md is on but the Verifier resolves to host-session, which the reflection hook cannot dispatch; set a concrete Verifier provider or turn the switch off\n' >&2
    rc=12
  fi
  role_manage_status || rc=$?
  return "$rc"
}

role_manage_test() {
  local target=${1:-} provider adapter
  case "$target" in
    planner|executor|verifier) provider="$(arkira_resolve_role "$target" provider)" || return $? ;;
    *) provider=$target ;;
  esac
  [[ -n "$provider" ]] || { role_manage_usage; return; }
  if [[ "$provider" == host-session ]]; then
    printf 'host-session\tauth=ok\n'
    return 0
  fi
  adapter="$(arkira_adapter_file "$provider")" || {
    arkira_error 11 "unknown provider $provider; configure a known adapter"
    return
  }
  arkira_auth_preflight "$adapter"
}

role_manage_publish() {
  local candidate=$1 repo config invalid=0
  repo="$(arkira_repo_root)" || return 16
  config="$repo/.arkira/roles.json"
  arkira_validate_role_candidate "$candidate" || return $?
  if role_manage_current_is_invalid "$repo"; then invalid=1; fi
  if [[ "$invalid" -eq 1 ]]; then
    arkira_backup_invalid_role_config "$repo" || return 1
  fi
  arkira_write_role_config "$repo" "$candidate"
}

role_manage_reset() {
  local candidate
  candidate="$(mktemp "${TMPDIR:-/tmp}/arkira-roles.XXXXXX")" || return 1
  arkira_mission_default_json > "$candidate"
  role_manage_publish "$candidate"
  local rc=$?
  rm -f -- "$candidate"
  return "$rc"
}

role_manage_set() {
  local role=${1:-} provider=${2:-} model=${3:-default} repo base candidate rc
  case "$role" in planner|executor|verifier) ;; *) role_manage_usage; return ;; esac
  [[ -n "$provider" ]] || { role_manage_usage; return; }
  repo="$(arkira_repo_root)" || return 16
  base="$(role_manage_render_base "$repo")" || return 16
  candidate="$(mktemp "${TMPDIR:-/tmp}/arkira-roles.XXXXXX")" || return 1
  if [[ "$model" == default || -z "$model" ]]; then
    printf '%s' "$base" | jq --arg role "$role" --arg provider "$provider" \
      '.roles[$role] = {provider:$provider}' > "$candidate"
  else
    printf '%s' "$base" | jq --arg role "$role" --arg provider "$provider" --arg model "$model" \
      '.roles[$role] = {provider:$provider,model:$model}' > "$candidate"
  fi
  role_manage_publish "$candidate"
  rc=$?
  rm -f -- "$candidate"
  return "$rc"
}

role_manage_main() {
  local command=${1:-}
  shift || true
  case "$command" in
    status) [[ "$#" -eq 0 ]] || { role_manage_usage; return; }; role_manage_status ;;
    doctor) [[ "$#" -eq 0 ]] || { role_manage_usage; return; }; role_manage_doctor ;;
    set) [[ "$#" -ge 2 && "$#" -le 3 ]] || { role_manage_usage; return; }; role_manage_set "$@" ;;
    test) [[ "$#" -eq 1 ]] || { role_manage_usage; return; }; role_manage_test "$@" ;;
    reset|repair) [[ "$#" -eq 0 ]] || { role_manage_usage; return; }; role_manage_reset ;;
    *) role_manage_usage ;;
  esac
}

role_manage_main "$@"
