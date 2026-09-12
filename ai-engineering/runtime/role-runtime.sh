#!/usr/bin/env bash
# Shared provider-independent role resolution and invocation primitives.

ARKIRA_ROLE_RUNTIME_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ARKIRA_AI_ENGINEERING_DIR="$(cd -- "$ARKIRA_ROLE_RUNTIME_DIR/.." && pwd -P)"
ARKIRA_ADAPTER_SCHEMA="$ARKIRA_AI_ENGINEERING_DIR/adapters/schema.json"
ARKIRA_ACTIVE_PGID=""
# shellcheck disable=SC1091  # Resolved relative to this runtime at execution.
. "$ARKIRA_AI_ENGINEERING_DIR/bootstrap/lib/file-safety.sh"

arkira_error() {
  local code=$1
  shift
  printf 'Arkira error %s: %s\n' "$code" "$*" >&2
  return "$code"
}

arkira_validate_json_schema() {
  local schema=${1:-} data=${2:-}
  # An absent schema is a packaging fault, not a malformed document. Callers report
  # "does not match its schema", which sends the operator to edit a correct file.
  if [[ ! -e "$schema" ]]; then
    printf 'arkira: schema not found: %s\n' "$schema" >&2
    return 1
  fi
  [[ -f "$schema" && ! -L "$schema" && -f "$data" && ! -L "$data" ]] || return 1
  jq -e . "$schema" >/dev/null 2>&1 || return 1
  jq -e . "$data" >/dev/null 2>&1 || return 1
  jq -n -e --slurpfile schema "$schema" --slurpfile data "$data" '
    def type_ok($want; $value):
      if $want == "object" then ($value | type) == "object"
      elif $want == "array" then ($value | type) == "array"
      elif $want == "string" then ($value | type) == "string"
      elif $want == "integer" then (($value | type) == "number" and ($value | floor) == $value)
      elif $want == "number" then ($value | type) == "number"
      elif $want == "boolean" then ($value | type) == "boolean"
      elif $want == "null" then $value == null
      else false end;
    def check($s; $v; $root):
      if ($s["$ref"]? | type) == "string" then
        ($s["$ref"] | sub("^#/"; "") | split("/") |
          reduce .[] as $part ($root; .[$part])) as $resolved |
        check($resolved; $v; $root)
      else
        (($s.type? == null) or type_ok($s.type; $v)) and
        (($s.enum? == null) or ($s.enum | index($v) != null)) and
        (($s.minimum? == null) or (($v | type) == "number" and $v >= $s.minimum)) and
        (($s.maximum? == null) or (($v | type) == "number" and $v <= $s.maximum)) and
        (($s.minLength? == null) or (($v | type) == "string" and ($v | length) >= $s.minLength)) and
        (($s.maxLength? == null) or (($v | type) == "string" and ($v | length) <= $s.maxLength)) and
        (($s.minItems? == null) or (($v | type) == "array" and ($v | length) >= $s.minItems)) and
        (($s.required? == null) or (($v | type) == "object" and
          ([$s.required[] as $key | $v | has($key)] | all))) and
        (($s.properties? == null) or (($v | type) == "object" and
          ([$s.properties | to_entries[] as $entry |
            if $v | has($entry.key) then check($entry.value; $v[$entry.key]; $root)
            else true end] | all))) and
        (($s.additionalProperties? != false) or (($v | type) == "object" and
          (($v | keys) - (($s.properties // {}) | keys) | length) == 0)) and
        (($s.items? == null) or (($v | type) == "array" and
          ([$v[] | check($s.items; .; $root)] | all)))
      end;
    check($schema[0]; $data[0]; $schema[0])
  ' >/dev/null 2>&1
}

arkira_validate_adapter_file() {
  local adapter=${1:-} schema_dir
  [[ -f "$adapter" && ! -L "$adapter" ]] || return 1
  jq -e . "$adapter" >/dev/null 2>&1 || return 1
  schema_dir="${ARKIRA_ADAPTERS_DIR:-$ARKIRA_AI_ENGINEERING_DIR/adapters}"
  if [[ -f "$schema_dir/schema.json" ]]; then
    arkira_validate_json_schema "$schema_dir/schema.json" "$adapter" || return 1
  elif [[ -f "$ARKIRA_ADAPTER_SCHEMA" ]]; then
    arkira_validate_json_schema "$ARKIRA_ADAPTER_SCHEMA" "$adapter" || return 1
  fi
  jq -e '
    def command_object:
      type == "object" and
      (.executable | type == "string" and length > 0) and
      (.args | type == "array" and all(.[]; type == "string"));
    . as $adapter |
    type == "object" and
    (.id | type == "string" and test("^[a-z0-9][a-z0-9-]*$")) and
    (.display_name | type == "string" and length > 0) and
    (.capabilities | type == "array" and length > 0 and
      all(.[]; IN("planning", "repo_reading", "code_editing", "structured_reviewing", "test_execution"))) and
    (.cli_binary | type == "string" and length > 0) and
    (.auth_check_command | command_object) and
    (.invocation | type == "object") and
    (.invocation | to_entries | all(.[];
      (.key as $key | $adapter.capabilities | index($key) != null) and
      (.value | type == "object") and
      (.value.executable | type == "string" and length > 0) and
      (.value.args | type == "array" and all(.[]; type == "string")) and
      (.value.input == "stdin") and
      ((.value.output | IN("text", "json")) or
        ($adapter.id == "claude-code" and .key == "structured_reviewing" and
         .value.output == "stream-json" and .value.schema_enforced == true)) and
      (.value.schema_enforced | type == "boolean")))
  ' "$adapter" >/dev/null 2>&1 || return 1
  if jq -r '[.auth_check_command.args[], (.invocation[]?.args[]?)] | .[]' "$adapter" 2>/dev/null |
    grep -oE '\{[^}]+\}' | grep -Ev '^\{(model|repo_root|schema_file|output_file|timeout_seconds)\}$' |
    grep -q .; then
    return 1
  fi
}

arkira_adapter_dir() {
  printf '%s' "${ARKIRA_ADAPTERS_DIR:-$ARKIRA_AI_ENGINEERING_DIR/adapters}"
}

arkira_adapter_file() {
  local provider=${1:-} file
  [[ "$provider" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  file="$(arkira_adapter_dir)/$provider.json"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  printf '%s' "$file"
}

arkira_adapter_is_verified_snapshot() {
  local adapter=$1 provider=$2 root manifest version
  local install_record record_entry install_path running_root
  if [[ "${ARKIRA_HARNESS_VERIFIED+x}" == x || "${ARKIRA_HARNESS_ROOT+x}" == x ]]; then
    [[ "${ARKIRA_HARNESS_VERIFIED:-}" == true ]] || return 1
    [[ -n "${ARKIRA_HARNESS_ROOT:-}" && -d "$ARKIRA_HARNESS_ROOT" && ! -L "$ARKIRA_HARNESS_ROOT" ]] || return 1
    root="$(cd -- "$ARKIRA_HARNESS_ROOT" && pwd -P)" || return 1
    version="${ARKIRA_HARNESS_VERSION:-}"
  else
    install_record="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/plugins/installed_plugins.json"
    jq -e '
      .version == 2 and
      (.plugins["arkira@arkira-labs-standards"] | type == "array" and length > 0)
    ' "$install_record" >/dev/null 2>&1 || return 1
    record_entry="$(jq -c '
      .plugins["arkira@arkira-labs-standards"] as $entries |
      (first($entries[] | select(.scope == "user")) // $entries[0])
    ' "$install_record" 2>/dev/null)" || return 1
    install_path="$(jq -r '.installPath // empty' <<<"$record_entry" 2>/dev/null)" || return 1
    [[ -n "$install_path" && -d "$install_path" && -r "$install_path" ]] || return 1
    root="$(cd -- "$install_path" && pwd -P)" || return 1
    running_root="$(cd -- "$ARKIRA_AI_ENGINEERING_DIR/.." && pwd -P)" || return 1
    [[ "$root" == "$running_root" ]] || return 1
    version="$(jq -r '.version // empty' <<<"$record_entry" 2>/dev/null)" || return 1
    [[ -n "$version" ]] || return 1
  fi
  [[ "$ARKIRA_AI_ENGINEERING_DIR" == "$root/ai-engineering" ]] || return 1
  [[ "$adapter" == "$root/ai-engineering/adapters/$provider.json" ]] || return 1
  [[ -f "$adapter" && ! -L "$adapter" ]] || return 1
  manifest="$root/.claude-plugin/plugin.json"
  [[ -f "$manifest" && ! -L "$manifest" && -r "$manifest" ]] || return 1
  jq -e --arg version "$version" \
    '.name == "arkira" and .version == $version' "$manifest" >/dev/null 2>&1 || return 1
  jq -e --arg id "$provider" '.id == $id' "$adapter" >/dev/null 2>&1
}

arkira_adapter_sha_is_trusted() {
  local adapter=$1 provider=$2 relative expected actual registry repo
  [[ -f "$adapter" && ! -L "$adapter" ]] || return 1
  [[ -n "${ARKIRA_ADAPTERS_DIR:-}" ]] && return 0
  arkira_adapter_is_verified_snapshot "$adapter" "$provider" && return 0
  repo="$(arkira_repo_root)" || return 1
  if [[ -f "$repo/.claude-plugin/plugin.json" && ! -L "$repo/.claude-plugin/plugin.json" \
    && "$ARKIRA_AI_ENGINEERING_DIR" == "$repo/ai-engineering" ]]; then
    return 0
  fi
  # A development snapshot captured from the target repository runs the
  # repository's own adapter; trust it when the bytes still match the source.
  if [[ -n "${ARKIRA_HOME_DEV:-}" && -d "$ARKIRA_HOME_DEV" && ! -L "$ARKIRA_HOME_DEV" ]] \
    && [[ "$(cd -- "$ARKIRA_HOME_DEV" && pwd -P)" == "$repo" ]] \
    && [[ -f "$repo/.claude-plugin/plugin.json" && ! -L "$repo/.claude-plugin/plugin.json" ]] \
    && [[ -f "$repo/ai-engineering/adapters/$provider.json" && ! -L "$repo/ai-engineering/adapters/$provider.json" ]] \
    && cmp -s -- "$adapter" "$repo/ai-engineering/adapters/$provider.json"; then
    return 0
  fi
  [[ "${ARKIRA_ALLOW_LOCAL_ADAPTER_OVERRIDE:-0}" == 1 ]] && {
    printf 'Arkira warning: local adapter override enabled for %s\n' "$provider" >&2
    return 0
  }
  registry="$repo/.arkira/sync-state.json"
  [[ -f "$registry" && ! -L "$registry" ]] || return 1
  relative="ai-engineering/adapters/$provider.json"
  expected="$(jq -r --arg path "$relative" '.files[$path].baseline_sha // empty' "$registry" 2>/dev/null)"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual="$(shasum -a 256 "$adapter" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]]
}

arkira_repo_root() {
  if [[ -n "${ARKIRA_REPO_ROOT:-}" ]]; then
    [[ -d "$ARKIRA_REPO_ROOT" && ! -L "$ARKIRA_REPO_ROOT" ]] || return 1
    (cd -- "$ARKIRA_REPO_ROOT" && pwd -P)
  else
    git rev-parse --show-toplevel 2>/dev/null
  fi
}

arkira_role_config_file() {
  local repo user_home
  repo="$(arkira_repo_root)" || return 1
  if [[ -f "$repo/.arkira/roles.json" || -L "$repo/.arkira/roles.json" ]]; then
    printf '%s' "$repo/.arkira/roles.json"
    return 0
  fi
  user_home="${ARKIRA_ROLE_HOME:-$HOME}"
  if [[ -f "$user_home/.arkira/roles.json" || -L "$user_home/.arkira/roles.json" ]]; then
    printf '%s' "$user_home/.arkira/roles.json"
    return 0
  fi
  return 1
}

arkira_role_default() {
  jq -er --arg role "$1" '.roles[$role] | [.provider,.model] | @tsv' \
    "$ARKIRA_ROLE_RUNTIME_DIR/model-catalog.json"
}

arkira_mission_default_json() {
  jq -c '{schema_version,roles}' "$ARKIRA_ROLE_RUNTIME_DIR/model-catalog.json"
}

arkira_role_required_capabilities() {
  case "$1" in
    planner) printf '%s\n' planning repo_reading ;;
    executor) printf '%s\n' code_editing test_execution ;;
    verifier) printf '%s\n' repo_reading structured_reviewing ;;
    *) return 1 ;;
  esac
}

arkira_host_has_capability() {
  case "$1" in planning|repo_reading|structured_reviewing) return 0 ;; *) return 1 ;; esac
}

arkira_validate_role_config_shape() {
  local config=$1
  [[ -f "$config" && ! -L "$config" ]] || return 1
  jq -e '
    . as $root |
    type == "object" and .schema_version == 1 and
    ($root.roles | type == "object") and
    (["planner", "executor", "verifier"] | all(. as $role |
      ($root.roles[$role] | type == "object") and
      ($root.roles[$role].provider | type == "string" and length > 0) and
      (($root.roles[$role].model? == null) or
        ($root.roles[$role].model | type == "string" and test("^[A-Za-z0-9._-]+$"))) and
      (($root.roles[$role].quick_model? == null) or
        ($root.roles[$role].quick_model | type == "string" and test("^[A-Za-z0-9._-]+$")))))
  ' "$config" >/dev/null 2>&1
}

arkira_validate_role_candidate() {
  local config=$1 role provider adapter required model quick_model
  arkira_validate_role_config_shape "$config" || return 16
  for role in planner executor verifier; do
    provider="$(jq -r --arg role "$role" '.roles[$role].provider' "$config")"
    model="$(jq -r --arg role "$role" '.roles[$role].model // empty' "$config")"
    quick_model="$(jq -r --arg role "$role" '.roles[$role].quick_model // empty' "$config")"
    [[ -z "$model" || "$model" =~ ^[A-Za-z0-9._-]+$ ]] || return 16
    [[ -z "$quick_model" || "$quick_model" =~ ^[A-Za-z0-9._-]+$ ]] || return 16
    if [[ "$provider" == host-session ]]; then
      while IFS= read -r required; do
        arkira_host_has_capability "$required" || return 12
      done < <(arkira_role_required_capabilities "$role")
    else
      adapter="$(arkira_adapter_file "$provider")" || return 11
      arkira_validate_adapter_file "$adapter" || return 11
      while IFS= read -r required; do
        jq -e --arg capability "$required" '.capabilities | index($capability) != null' \
          "$adapter" >/dev/null || return 12
      done < <(arkira_role_required_capabilities "$role")
    fi
  done
}

arkira_role_config_error() {
  local config=$1 rc
  if [[ -L "$config" ]]; then printf 'roles.json must not be a symlink'; return; fi
  if ! jq -e . "$config" >/dev/null 2>&1; then printf 'roles.json is malformed JSON'; return; fi
  if [[ "$(jq -r '.schema_version // empty' "$config")" != 1 ]]; then
    printf 'roles.json schema_version must be 1'
    return
  fi
  arkira_validate_role_candidate "$config" >/dev/null 2>&1
  rc=$?
  case "$rc" in
    11) printf 'roles.json references an unknown or invalid provider' ;;
    12) printf 'roles.json assigns a provider without the role capabilities' ;;
    16) printf 'roles.json has an invalid role, provider, or model shape' ;;
    *) printf 'roles.json is invalid' ;;
  esac
}

arkira_backup_invalid_role_config() {
  local repo=$1 current="$1/.arkira/roles.json"
  [[ -f "$current" && ! -L "$current" ]] || return 1
  arkira_atomic_copy "$repo" ".arkira/roles.json.corrupt" "$current"
}

arkira_write_role_config() {
  local repo=$1 source=$2 target="$1/.arkira/roles.json"
  [[ -f "$source" && ! -L "$source" ]] || return 1
  chmod 600 "$source" || return 1
  if [[ -e "$target" || -L "$target" ]]; then
    arkira_atomic_copy "$repo" ".arkira/roles.json" "$source"
  else
    arkira_atomic_copy_new_with_identity "$repo" ".arkira/roles.json" "$source" >/dev/null
  fi
}

arkira_resolve_role() {
  local role=${1:-} field=${2:-provider} config provider model quick_model='' adapter required
  case "$role" in planner|executor|verifier) ;; *) arkira_error 16 "unknown role; use planner, executor, or verifier"; return ;; esac
  if config="$(arkira_role_config_file 2>/dev/null)"; then
    arkira_validate_role_config_shape "$config" || {
      arkira_error 16 "invalid roles.json; run arkira-role doctor or repair"
      return
    }
    provider="$(jq -r --arg role "$role" '.roles[$role].provider' "$config")"
    model="$(jq -r --arg role "$role" '.roles[$role].model // empty' "$config")"
    quick_model="$(jq -r --arg role "$role" '.roles[$role].quick_model // empty' "$config")"
  else
    IFS=$'\t' read -r provider model <<<"$(arkira_role_default "$role")"
  fi
  if [[ "$provider" == host-session ]]; then
    while IFS= read -r required; do
      arkira_host_has_capability "$required" || {
        arkira_error 12 "host-session lacks $required for $role; choose a capable provider"
        return
      }
    done < <(arkira_role_required_capabilities "$role")
    model=""
    quick_model=""
  else
    adapter="$(arkira_adapter_file "$provider")" || {
      arkira_error 11 "unknown provider $provider; install or configure a known adapter"
      return
    }
    arkira_validate_adapter_file "$adapter" || {
      arkira_error 11 "invalid adapter $provider; restore the canonical adapter"
      return
    }
    while IFS= read -r required; do
      jq -e --arg capability "$required" '.capabilities | index($capability) != null' "$adapter" >/dev/null || {
        arkira_error 12 "$provider lacks $required for $role; choose a capable provider"
        return
      }
    done < <(arkira_role_required_capabilities "$role")
    if [[ -z "$model" ]]; then
      model="$(jq -r '.default_model // empty' "$adapter")"
    fi
    if [[ -z "$quick_model" ]]; then quick_model=$model; fi
    [[ -z "$model" || "$model" =~ ^[A-Za-z0-9._-]+$ ]] \
      && [[ -z "$quick_model" || "$quick_model" =~ ^[A-Za-z0-9._-]+$ ]] || {
      arkira_error 16 "unsafe model in roles.json; use letters, digits, dot, underscore, or hyphen"
      return
    }
  fi
  case "$field" in
    provider) printf '%s' "$provider" ;;
    model) printf '%s' "$model" ;;
    quick_model) printf '%s' "$quick_model" ;;
    *) arkira_error 16 "unknown role field $field; use provider, model, or quick_model" ;;
  esac
}

arkira_role_is_inline() {
  [[ "$(arkira_resolve_role "$1" provider)" == host-session ]]
}

arkira_resolve_effort() {
  local adapter=${1:-} capability=${2:-}
  [[ -f "$adapter" && ! -L "$adapter" ]] || return 1
  jq -r --arg capability "$capability" '
    (.invocation[$capability].args // []) as $args |
    ($args | index("--effort")) as $flag |
    if $flag != null and ($args[$flag + 1] | type) == "string" then $args[$flag + 1]
    else
      ([range(0; $args | length) as $index |
        select($args[$index] == "-c") | $args[$index + 1] |
        select(type == "string" and startswith("model_reasoning_effort="))][0] // "") |
      sub("^model_reasoning_effort=\\\"?"; "") | sub("\\\"?$"; "")
    end
  ' "$adapter"
}

arkira_effort_supported() {
  local adapter=${1:-} effort=${2:-}
  [[ -f "$adapter" && ! -L "$adapter" && -n "$effort" ]] || return 1
  jq -e --arg effort "$effort" '
    (.supported_efforts | type == "array" and length > 0) and
    (.supported_efforts | index($effort) != null)
  ' "$adapter" >/dev/null 2>&1
}

# shellcheck disable=SC1091  # Resolved relative to this runtime at execution.
. "$ARKIRA_ROLE_RUNTIME_DIR/tier-routing.sh"

arkira_auth_preflight() {
  local adapter=$1 executable arg
  local -a command_args=()
  executable="$(jq -r '.auth_check_command.executable' "$adapter")"
  command -v "$executable" >/dev/null 2>&1 || {
    arkira_error 13 "provider binary $executable is missing; install it and retry"
    return
  }
  while IFS= read -r arg; do command_args+=("$arg"); done < <(jq -r '.auth_check_command.args[]' "$adapter")
  if [[ "${#command_args[@]}" -gt 0 ]]; then
    "$executable" "${command_args[@]}" >/dev/null 2>&1
  else
    "$executable" >/dev/null 2>&1
  fi || {
    arkira_error 10 "provider is not authenticated; complete its login flow and retry"
    return
  }
}

arkira_build_command() {
  local adapter=$1 capability=$2 model=$3 repo_root=$4 schema_file=$5 output_file=$6 timeout=$7
  local executable arg previous="" skip_model_value=0 provider schema_value
  provider="$(jq -r '.id' "$adapter")"
  schema_value=$schema_file
  if [[ "$provider" == claude-code && -n "$schema_file" ]]; then
    schema_value="$(jq -c . "$schema_file")" || return 1
  fi
  executable="$(jq -r --arg capability "$capability" '.invocation[$capability].executable // empty' "$adapter")"
  [[ -n "$executable" ]] || return 1
  printf '%s\0' "$executable"
  while IFS= read -r arg; do
    if [[ -z "$model" && "$arg" == "{model}" && ( "$previous" == -m || "$previous" == --model ) ]]; then
      skip_model_value=1
      previous=$arg
      continue
    fi
    if [[ -z "$model" && ( "$arg" == -m || "$arg" == --model ) ]]; then
      previous=$arg
      continue
    fi
    if [[ "$skip_model_value" -eq 1 ]]; then skip_model_value=0; fi
    arg="${arg//\{model\}/$model}"
    arg="${arg//\{repo_root\}/$repo_root}"
    arg="${arg//\{schema_file\}/$schema_value}"
    arg="${arg//\{output_file\}/$output_file}"
    arg="${arg//\{timeout_seconds\}/$timeout}"
    printf '%s\0' "$arg"
    previous=$arg
  done < <(jq -r --arg capability "$capability" '.invocation[$capability].args[]' "$adapter")
}

# Normalize provider token usage out of the raw provider envelope before the envelope is discarded.
# Two shapes are handled: Anthropic-style input_tokens/output_tokens and OpenAI-style
# prompt_tokens/completion_tokens. A provider that reports nothing is recorded as reporting nothing.
# Counts are never estimated, derived, or synthesized.
# Cache fields are carried through because a provider that caches its prompt reports a tiny
# input_tokens; recording that alone would understate real cost in a qualification report.
arkira_extract_usage() {
  local raw=${1:-}
  local unreported='{"status":"not_reported_by_provider","input_tokens":null,"output_tokens":null,"cache_read_input_tokens":null,"cache_creation_input_tokens":null}'
  local normalized=""
  [[ -f "$raw" && -s "$raw" ]] || { printf '%s' "$unreported"; return 0; }
  normalized="$(jq -c -s '
    def number_or_null($value): if ($value | type) == "number" then $value else null end;
    (.[0] // {}) as $envelope |
    (if ($envelope | type) == "object" then $envelope else {} end) as $root |
    ($root.usage // $root.response.usage // $root.message.usage // {}) as $raw_usage |
    (if ($raw_usage | type) == "object" then $raw_usage else {} end) as $usage |
    (if ($usage.input_tokens | type) == "number" then $usage.input_tokens
     elif ($usage.prompt_tokens | type) == "number" then $usage.prompt_tokens
     else null end) as $input |
    (if ($usage.output_tokens | type) == "number" then $usage.output_tokens
     elif ($usage.completion_tokens | type) == "number" then $usage.completion_tokens
     else null end) as $output |
    number_or_null($usage.cache_read_input_tokens) as $cache_read |
    number_or_null($usage.cache_creation_input_tokens) as $cache_creation |
    if $input == null and $output == null and $cache_read == null and $cache_creation == null
    then {status:"not_reported_by_provider",input_tokens:null,output_tokens:null,
      cache_read_input_tokens:null,cache_creation_input_tokens:null}
    else {status:"reported",input_tokens:$input,output_tokens:$output,
      cache_read_input_tokens:$cache_read,cache_creation_input_tokens:$cache_creation} end
  ' "$raw" 2>/dev/null)" || normalized=""
  if printf '%s' "$normalized" | jq -e -s \
    'length == 1 and (.[0] | type) == "object"' >/dev/null 2>&1; then
    printf '%s' "$normalized"
  else
    printf '%s' "$unreported"
  fi
}

# Emits the timeout watcher program. Extracted so the owning suite can start the real watcher
# against an owner it is not a child of, which is how the startup race is tested.
arkira_timeout_watcher_program() {
  cat <<'PERL'
use strict;
use warnings;
my ($seconds, $pgid, $marker_path, $owner) = @ARGV;
my $deadline = time + $seconds;
while (1) {
  exit 0 if getppid() != $owner;
  my $left = $deadline - time;
  last if $left <= 0;
  sleep($left > 1 ? 1 : $left);
}
exit 0 if getppid() != $owner;
open my $handle, ">", $marker_path or exit 1;
close $handle;
kill "TERM", -$pgid;
select undef, undef, undef, 1;
kill "KILL", -$pgid;
PERL
}

arkira_run_with_timeout() {
  local stdout_path=$1 stderr_path=$2 timeout_seconds=$3 stdin_path=$4 pid watcher status marker owner program
  shift 4
  marker="$(mktemp "${TMPDIR:-/tmp}/arkira-timeout.XXXXXX")" || return 1
  rm -f -- "$marker"
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" < "$stdin_path" > "$stdout_path" 2> "$stderr_path" &
  elif command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e 'POSIX::setsid() or die "setsid failed: $!"; exec @ARGV' -- \
      "$@" < "$stdin_path" > "$stdout_path" 2> "$stderr_path" &
  else
    printf 'Arkira error 13: setsid or perl is required for process isolation\n' >&2
    return 13
  fi
  pid=$!
  ARKIRA_ACTIVE_PGID=$pid
  # Bash 3.2 has no BASHPID. exec avoids a second fork that could report the ephemeral
  # command-substitution shell instead of the owning shell.
  owner=$(exec sh -c 'echo $PPID')
  program="$(arkira_timeout_watcher_program)"
  (
    trap - EXIT
    exec perl -e "$program" \
      "$timeout_seconds" "$pid" "$marker" "$owner"
  ) &
  watcher=$!
  if wait "$pid"; then status=0; else status=$?; fi
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  ARKIRA_ACTIVE_PGID=""
  if [[ -e "$marker" ]]; then
    rm -f -- "$marker"
    return 14
  fi
  rm -f -- "$marker"
  return "$status"
}

arkira_stop_active_process_group() {
  if [[ "$ARKIRA_ACTIVE_PGID" =~ ^[1-9][0-9]*$ ]]; then
    kill -TERM "-$ARKIRA_ACTIVE_PGID" 2>/dev/null || true
    sleep 1
    kill -KILL "-$ARKIRA_ACTIVE_PGID" 2>/dev/null || true
    ARKIRA_ACTIVE_PGID=""
  fi
}
