#!/usr/bin/env bash

if [[ $- == *x* ]]; then
  set +x
  printf '%s\n' 'shell tracing is not permitted for this command' >&2
  exit 2
fi

set -euo pipefail
umask 077

emit_failure() {
  local exit_code=$1 message=$2 status=failure
  [ "$exit_code" -ne 31 ] || status=indeterminate
  printf '{"timestamp":"%s","wrapper_version":"0.134.15","project_ref":null,"target":null,"action":"reset-password","password_mode":null,"status":"%s","exit_code":%s,"request_id":null}\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$status" "$exit_code"
  printf '%s\n' "$message" >&2
  exit "$exit_code"
}

read_hidden_password() {
  local password='' password_confirmation=''
  IFS= read -r -s -p 'New password: ' password \
    || emit_failure 21 'hidden password input failed'
  printf '\n' >&2
  IFS= read -r -s -p 'Confirm password: ' password_confirmation \
    || emit_failure 21 'hidden password confirmation failed'
  printf '\n' >&2
  stty echo 2>/dev/null || true
  [ -n "$password" ] \
    || emit_failure 21 'replacement password cannot be empty'
  [ "$password" = "$password_confirmation" ] \
    || emit_failure 21 'replacement passwords did not match'
  RESET_AUTH_PASSWORD=$password
  password=''
  password_confirmation=''
}

run_prompt_helper() {
  local node_bin=$1 helper=$2 password=$3 status=0
  shift 3
  printf '%s\n' "$password" | "$node_bin" "$helper" "$@" || status=$?
  password=''
  return "$status"
}

main() {
  local project_ref='' user_email='' user_id='' password_source=''
  local reveal_generated='' confirm_action='' flag value script_dir helper node_bin status
  local -a forward_args

  while [ "$#" -gt 0 ]; do
    flag=$1
    case "$flag" in
      --project-ref|--user-email|--user-id|--password-source|--reveal-generated|--confirm-action)
        [ "$#" -ge 2 ] || emit_failure 2 'invalid or incomplete arguments'
        value=$2
        [ -n "$value" ] || emit_failure 2 'invalid or incomplete arguments'
        shift 2
        ;;
      *) emit_failure 2 'unknown argument' ;;
    esac

    case "$flag" in
      --project-ref)
        [ -z "$project_ref" ] || emit_failure 2 'duplicate argument'
        project_ref=$value
        ;;
      --user-email)
        [ -z "$user_email" ] || emit_failure 2 'duplicate argument'
        user_email=$value
        ;;
      --user-id)
        [ -z "$user_id" ] || emit_failure 2 'duplicate argument'
        user_id=$value
        ;;
      --password-source)
        [ -z "$password_source" ] || emit_failure 2 'duplicate argument'
        password_source=$value
        ;;
      --reveal-generated)
        [ -z "$reveal_generated" ] || emit_failure 2 'duplicate argument'
        reveal_generated=$value
        ;;
      --confirm-action)
        [ -z "$confirm_action" ] || emit_failure 2 'duplicate argument'
        confirm_action=$value
        ;;
    esac
  done

  [[ "$project_ref" =~ ^[a-z0-9]{20}$ ]] \
    || emit_failure 2 'invalid project reference'
  if { [ -n "$user_email" ] && [ -n "$user_id" ]; } \
    || { [ -z "$user_email" ] && [ -z "$user_id" ]; }; then
    emit_failure 2 'supply exactly one auth user selector'
  fi
  if [ -n "$user_email" ]; then
    [[ "$user_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
      || emit_failure 2 'invalid auth user email'
  else
    [[ "$user_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-4[0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$ ]] \
      || emit_failure 2 'invalid auth user UUID'
  fi
  [ "$confirm_action" = reset-password ] \
    || emit_failure 2 'invalid confirmation action'
  case "$password_source" in
    generate)
      [ "$reveal_generated" = yes ] \
        || emit_failure 2 'generated mode requires one warned password emission'
      ;;
    prompt)
      [ -z "$reveal_generated" ] \
        || emit_failure 2 'prompt mode does not reveal a password'
      ;;
    *) emit_failure 2 'invalid password source' ;;
  esac

  script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  helper="$script_dir/reset-auth-password.mjs"
  [ -f "$helper" ] && [ ! -L "$helper" ] \
    || emit_failure 10 'fixed reset helper is unavailable'
  node_bin="$(command -v node 2>/dev/null || true)"
  [ -n "$node_bin" ] \
    || emit_failure 10 'Node is unavailable'

  forward_args=(
    --project-ref "$project_ref"
    --password-source "$password_source"
    --confirm-action reset-password
  )
  if [ -n "$user_email" ]; then
    forward_args+=(--user-email "$user_email")
  else
    forward_args+=(--user-id "$user_id")
  fi

  if [ "$password_source" = generate ]; then
    forward_args+=(--reveal-generated yes)
    exec "$node_bin" "$helper" "${forward_args[@]}"
  fi

  [ -t 0 ] || emit_failure 21 'prompt mode requires an interactive terminal'
  RESET_AUTH_PASSWORD=''
  restore_terminal() {
    stty echo 2>/dev/null || true
  }
  trap restore_terminal EXIT HUP INT TERM
  read_hidden_password
  trap - EXIT HUP INT TERM
  status=0
  run_prompt_helper "$node_bin" "$helper" "$RESET_AUTH_PASSWORD" "${forward_args[@]}" \
    || status=$?
  RESET_AUTH_PASSWORD=''
  return "$status"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
