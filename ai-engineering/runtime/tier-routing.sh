# shellcheck shell=bash
# Structured, upward-only Arkira tier routing primitives.

ARKIRA_TIER_ROUTING_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ARKIRA_TIER_ROUTING_POLICY="$ARKIRA_TIER_ROUTING_DIR/tier-routing-policy.json"
ARKIRA_TIER_ROUTING_MANIFEST_SCHEMA="$ARKIRA_TIER_ROUTING_DIR/schemas/risk-paths.json"

arkira_tier_error() {
  printf 'tier routing: %s\n' "$*" >&2
  return 1
}

arkira_tier_rank() {
  case "${1:-}" in
    quick) printf 1 ;;
    normal) printf 2 ;;
    elevated) printf 3 ;;
    high-assurance) printf 4 ;;
    *) printf 0 ;;
  esac
}

arkira_tier_sha256_file() {
  local path=${1:-}
  [[ -f "$path" && ! -L "$path" ]] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    arkira_tier_error 'no SHA-256 implementation is available'
  fi
}

arkira_tier_policy_valid() {
  local policy=${1:-$ARKIRA_TIER_ROUTING_POLICY}
  [[ -f "$policy" && ! -L "$policy" ]] || {
    arkira_tier_error 'central policy is missing or unsafe'; return 1; }
  jq -e '
    def exact_keys($keys): (keys_unsorted | sort) == ($keys | sort);
    def rule_array($field; $value_pattern):
      ($field | type == "array" and length > 0) and
      all($field[];
        exact_keys(["id", $value_pattern.key]) and
        (.id | type == "string" and test("^[a-z0-9][a-z0-9.-]{0,95}$")) and
        (.[$value_pattern.key] | type == "array" and length > 0) and
        all(.[$value_pattern.key][];
          type == "string" and length > 0 and test($value_pattern.pattern)));
    exact_keys(["schema_version", "policy_version", "token_rules", "directory_rules", "root_prefix_rules", "exact_path_rules"]) and
    .schema_version == 1 and
    (.policy_version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    rule_array(.token_rules; {key:"terms",pattern:"^[a-z0-9][a-z0-9]*$"}) and
    rule_array(.directory_rules; {key:"terms",pattern:"^\\.?[a-z0-9][a-z0-9.-]*$"}) and
    rule_array(.root_prefix_rules; {key:"prefixes",pattern:"^[a-z0-9.][a-z0-9._/-]*$"}) and
    rule_array(.exact_path_rules; {key:"paths",pattern:"^[a-z0-9.][a-z0-9._/-]*$"}) and
    ([.token_rules[].id, .directory_rules[].id, .root_prefix_rules[].id, .exact_path_rules[].id] as $ids |
      ($ids | length) == ($ids | unique | length)) and
    all(.root_prefix_rules[].prefixes[]; startswith("/") | not) and
    all(.root_prefix_rules[].prefixes[]; contains("//") | not) and
    all(.root_prefix_rules[].prefixes[]; split("/") | all(. != "." and . != "..")) and
    all(.exact_path_rules[].paths[]; startswith("/") | not) and
    all(.exact_path_rules[].paths[]; contains("//") | not) and
    all(.exact_path_rules[].paths[]; split("/") | all(. != "." and . != ".."))
  ' "$policy" >/dev/null 2>&1 || {
    arkira_tier_error 'central policy is malformed or unsupported'; return 1; }
}

arkira_tier_policy_digest() {
  arkira_tier_policy_valid "$ARKIRA_TIER_ROUTING_POLICY" || return 1
  arkira_tier_sha256_file "$ARKIRA_TIER_ROUTING_POLICY"
}

arkira_tier_path_valid() {
  local path=${1:-} part
  [[ -n "$path" && "$path" != /* && "$path" != */ && "$path" != *//* ]] || return 1
  while IFS= read -r part; do
    [[ -n "$part" && "$part" != . && "$part" != .. ]] || return 1
  done < <(printf '%s' "$path" | tr '/' '\n')
}

arkira_tier_nul_stream_complete() {
  local path=${1:-} last
  [[ -f "$path" && -r "$path" && ! -L "$path" ]] || return 1
  [[ -s "$path" ]] || return 0
  last="$(LC_ALL=C od -An -tu1 "$path" | awk '{for (i=1; i<=NF; i++) value=$i} END {print value}')" || return 1
  [[ "$last" == 0 ]]
}

arkira_tier_manifest_glob_valid() {
  local glob=${1:-} part
  [[ -n "$glob" && "$glob" != /* && "$glob" != */ && "$glob" != *//* ]] || return 1
  [[ "$glob" != *'!'* && "$glob" != *'?'* && "$glob" != *'['* && "$glob" != *']'* \
    && "$glob" != *'{'* && "$glob" != *'}'* && "$glob" != *'\\'* ]] || return 1
  while IFS= read -r part; do
    [[ -n "$part" && "$part" != . && "$part" != .. ]] || return 1
    if [[ "$part" == *'**'* && "$part" != '**' ]]; then return 1; fi
  done < <(printf '%s' "$glob" | tr '/' '\n')
}

arkira_tier_manifest_valid() {
  local manifest=${1:-} glob
  [[ -f "$ARKIRA_TIER_ROUTING_MANIFEST_SCHEMA" && ! -L "$ARKIRA_TIER_ROUTING_MANIFEST_SCHEMA" ]] || {
    arkira_tier_error 'repository manifest schema is missing or unsafe'; return 1; }
  jq -e . "$ARKIRA_TIER_ROUTING_MANIFEST_SCHEMA" >/dev/null 2>&1 || {
    arkira_tier_error 'repository manifest schema is malformed'; return 1; }
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
  jq -e '
    (keys_unsorted | sort) == (["schema_version", "elevated_paths"] | sort) and
    .schema_version == 1 and
    (.elevated_paths | type == "array") and
    all(.elevated_paths[];
      (keys_unsorted | sort) == (["id", "glob"] | sort) and
      (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$")) and
      (.glob | type == "string" and length > 0)) and
    ([.elevated_paths[].id] as $ids | ($ids | length) == ($ids | unique | length))
  ' "$manifest" >/dev/null 2>&1 || return 1
  while IFS= read -r glob; do
    arkira_tier_manifest_glob_valid "$glob" || return 1
  done < <(jq -r '.elevated_paths[].glob' "$manifest")
}

arkira_tier_load_manifest() {
  local repo=$1 object=$2 source=$3 output=$4 temp=$5 entry metadata mode kind blob digest
  entry="$(git -C "$repo" ls-tree "$object" -- .arkira/risk-paths.json 2>/dev/null)" || return 1
  if [[ -z "$entry" ]]; then
    jq -cn --arg source "$source" '{source:$source,present:false,digest:null,rules:[]}' > "$output"
    return
  fi
  metadata=${entry%%$'\t'*}
  IFS=' ' read -r mode kind blob <<< "$metadata"
  [[ "$mode" == 100644 && "$kind" == blob && "$blob" =~ ^[0-9a-f]{40}$ ]] || {
    arkira_tier_error "$source repository manifest is not a regular file"; return 1; }
  git -C "$repo" cat-file blob "$blob" > "$temp" || return 1
  arkira_tier_manifest_valid "$temp" || {
    arkira_tier_error "$source repository manifest is malformed or unsupported"; return 1; }
  digest="$(arkira_tier_sha256_file "$temp")" || return 1
  jq -c --arg source "$source" --arg digest "$digest" \
    '{source:$source,present:true,digest:$digest,rules:[.elevated_paths[] | . + {source:$source}]}' \
    "$temp" > "$output"
}

ARKIRA_TIER_MATCH_JQ='
  def component_tokens:
    gsub("(?<a>[A-Z]+)(?<b>[A-Z][a-z])|(?<c>[a-z0-9])(?<d>[A-Z])";
      "\(.a // .c) \(.b // .d)") |
    gsub("[._ -]+"; "\n") | ascii_downcase | split("\n") |
    map(select(test("[^ \\t\\r\\n\\f\\v]")));
  def central_matches($path; $operation; $policy):
    ($path | split("\n")[0] | split("/")) as $components |
    ($path | ascii_downcase) as $normalized_path |
    ([$components[0:-1][] | component_tokens[]] | unique) as $directory_tokens |
    ([$components[-1] | component_tokens[]] | unique) as $filename_tokens |
    (($directory_tokens + $filename_tokens) | unique) as $tokens |
    ([ $components[0:-1][] as $component |
       ($component | ascii_downcase) as $normalized |
       $policy.directory_rules[] | select(.terms | index($normalized)) |
       {rule_id:.id,source:"central",signal:"directory-component",path:$path,
        operation:$operation,matched:$normalized} ] +
     [ $tokens[] as $token | $policy.token_rules[] | select(.terms | index($token)) |
       {rule_id:.id,source:"central",
        signal:(if $directory_tokens | index($token) then "directory-token" else "filename-token" end),
        path:$path,operation:$operation,matched:$token,normalized_tokens:$tokens} ] +
     [ $policy.root_prefix_rules[] as $rule | $rule.prefixes[] as $prefix |
       select($normalized_path == $prefix or ($normalized_path | startswith($prefix + "/"))) |
       {rule_id:$rule.id,source:"central",signal:"root-prefix",path:$path,
        operation:$operation,matched:$prefix} ] +
     [ $policy.exact_path_rules[] as $rule | $rule.paths[] as $exact |
       select($normalized_path == $exact) |
       {rule_id:$rule.id,source:"central",signal:"exact-path",path:$path,
        operation:$operation,matched:$exact} ]);
  def regex_literal:
    . as $char | if (".+()|^$?{}[]\\" | contains($char)) then "\\" + $char else $char end;
  def glob_regex:
    reduce (split(""))[] as $char ({pattern:"",escaped:false};
      if .escaped then {pattern:(.pattern + ($char | regex_literal)),escaped:false}
      elif $char == "\\" then .escaped = true
      elif $char == "*" then .pattern += ".*"
      else .pattern += ($char | regex_literal) end) |
    .pattern + (if .escaped then "\\\\" else "" end);
  def glob_at($path; $pattern; $i; $j):
    if $j == ($pattern | length) then $i == ($path | length)
    elif $pattern[$j] == "**" then
      glob_at($path; $pattern; $i; $j + 1) or
      ($i < ($path | length) and glob_at($path; $pattern; $i + 1; $j))
    else
      $i < ($path | length) and
      ($path[$i] | test("^" + ($pattern[$j] | glob_regex) + "$")) and
      glob_at($path; $pattern; $i + 1; $j + 1)
    end;
  def repository_matches($path; $operation; $rules):
    ($path | split("\n")[0] | ascii_downcase | split("/")) as $parts |
    [ $rules[] as $rule |
      select(glob_at($parts; ($rule.glob | ascii_downcase | split("/")); 0; 0)) |
      {rule_id:$rule.id,source:"repository",signal:"glob",path:$path,
       operation:$operation,matched:$rule.glob,rule_sources:$rule.sources} ];
'

arkira_tier_exclusions_valid() {
  local exclusions=$1
  [[ -f "$exclusions" && ! -L "$exclusions" ]] || return 1
  jq -e '
    type == "array" and
    all(.[];
      (.path | type == "string" and length > 0) and
      (
        ((keys_unsorted | sort) == (["path", "receipt_ids"] | sort) and
          (.receipt_ids | type == "array" and length > 0) and
          all(.receipt_ids[]; type == "string" and test("^receipt-[0-9]+-[0-9]+-[0-9]+$")) and
          (.receipt_ids | length) == (.receipt_ids | unique | length)) or
        ((keys_unsorted | sort) == (["path", "verified_harness_sha"] | sort) and
          (.verified_harness_sha | type == "string" and test("^[a-f0-9]{40}$"))) or
        ((keys_unsorted | sort) == (["path", "mechanical_metadata"] | sort) and
          (.mechanical_metadata == true))
      )) and
    ([.[].path] as $paths | ($paths | length) == ($paths | unique | length))
  ' "$exclusions" >/dev/null 2>&1
}

arkira_tier_route_stream() (
  local repo=$1 base=$2 tree=$3 floor=$4 floor_source=$5 stream=$6 exclusions=$7
  local temp policy_digest schema_digest base_manifest candidate_manifest combined_rules
  local metadata old_mode new_mode old_blob new_blob status extra path
  [[ "$(arkira_tier_rank "$floor")" -ge 1 && "$(arkira_tier_rank "$floor")" -le 3 ]] || {
    arkira_tier_error 'tier floor is invalid'; return 1; }
  [[ -n "$floor_source" ]] || { arkira_tier_error 'tier floor source is empty'; return 1; }
  arkira_tier_policy_valid "$ARKIRA_TIER_ROUTING_POLICY" || return 1
  policy_digest="$(arkira_tier_sha256_file "$ARKIRA_TIER_ROUTING_POLICY")" || return 1
  schema_digest="$(arkira_tier_sha256_file "$ARKIRA_TIER_ROUTING_MANIFEST_SCHEMA")" || return 1
  arkira_tier_nul_stream_complete "$stream" || { arkira_tier_error 'candidate diff stream is malformed'; return 1; }
  arkira_tier_exclusions_valid "$exclusions" || { arkira_tier_error 'exact exclusion record is malformed'; return 1; }
  temp="$(mktemp -d "${TMPDIR:-/tmp}/arkira-tier-routing.XXXXXX")" || return 1
  trap 'rm -rf -- "$temp"' EXIT
  base_manifest="$temp/base-manifest.json"; candidate_manifest="$temp/candidate-manifest.json"
  arkira_tier_load_manifest "$repo" "$base" base "$base_manifest" "$temp/base-risk-paths.json" || return 1
  arkira_tier_load_manifest "$repo" "$tree" candidate "$candidate_manifest" "$temp/candidate-risk-paths.json" || return 1
  combined_rules="$temp/combined-rules.json"
  jq -s '[.[0].rules[], .[1].rules[]] | sort_by(.id,.glob,.source) |
    group_by([.id,.glob]) | map({id:.[0].id,glob:.[0].glob,sources:(map(.source)|unique|sort)})' \
    "$base_manifest" "$candidate_manifest" > "$combined_rules" || return 1
  while IFS= read -r -d '' metadata; do
    IFS= read -r -d '' path || { arkira_tier_error 'candidate diff stream has an incomplete path record'; return 1; }
    metadata=${metadata#:}
    IFS=' ' read -r old_mode new_mode old_blob new_blob status extra <<< "$metadata"
    [[ -z "${extra:-}" && "$old_mode" =~ ^[0-7]{6}$ && "$new_mode" =~ ^[0-7]{6}$ \
      && "$old_blob" =~ ^[0-9a-f]{40}$ && "$new_blob" =~ ^[0-9a-f]{40}$ \
      && "$status" =~ ^[AMDT]$ ]] || { arkira_tier_error 'candidate diff metadata is malformed or unsupported'; return 1; }
    arkira_tier_path_valid "$path" || { arkira_tier_error 'candidate diff path is malformed'; return 1; }
  done < "$stream"
  jq -cn --rawfile diff "$stream" --slurpfile policy "$ARKIRA_TIER_ROUTING_POLICY" \
    --slurpfile rules "$combined_rules" --slurpfile excluded "$exclusions" \
    --slurpfile base_manifest "$base_manifest" --slurpfile candidate_manifest "$candidate_manifest" \
    --arg floor "$floor" --arg floor_source "$floor_source" \
    --arg policy_digest "$policy_digest" --arg schema_digest "$schema_digest" \
    --arg base "$base" --arg tree "$tree" "$ARKIRA_TIER_MATCH_JQ"'
      ($diff | split("\u0000") | .[:-1]) as $fields |
      [range(0; $fields | length; 2) as $index |
        ($fields[$index] | ltrimstr(":") | split(" ")) as $metadata |
        {path:$fields[$index + 1],
         operation:({A:"added",M:"modified",D:"deleted",T:"type-change"}[$metadata[4]]),
         old_mode:$metadata[0],new_mode:$metadata[1],old_blob:$metadata[2],new_blob:$metadata[3]}] as $operations |
      $excluded[0] as $excluded_paths |
      ([ $operations[] as $entry |
         select(all($excluded_paths[]; .path != $entry.path)) |
         (central_matches($entry.path; $entry.operation; $policy[0]) +
          repository_matches($entry.path; $entry.operation; $rules[0]))[] ] |
        unique_by([.rule_id,.path,.operation,.signal,.matched]) |
        sort_by(.path,.rule_id,.signal,.matched)) as $matches |
      ([ $operations[] as $entry | select($entry.operation == "type-change") |
         select(all($excluded_paths[]; .path != $entry.path)) |
         {rule_id:"routing.ambiguous-type-change",path:$entry.path,operation:$entry.operation} ] |
        unique_by([.rule_id,.path,.operation]) | sort_by(.path,.rule_id)) as $ambiguities |
      [ $operations[] as $entry | $excluded_paths[] | select(.path == $entry.path) |
        . + {operation:$entry.operation} ] as $exclusions |
      {schema_version:1,final_tier:(if ($matches | length) > 0 or ($ambiguities | length) > 0
        then "elevated" else $floor end),floor:{tier:$floor,source:$floor_source},
       policy:{schema_version:1,version:$policy[0].policy_version,digest:$policy_digest},
       manifest_schema_digest:$schema_digest,trusted_base:$base,candidate_tree:$tree,
       manifests:{base:$base_manifest[0],candidate:$candidate_manifest[0]},
       effective_repository_rules:$rules[0],operations:($operations | sort_by(.path,.operation)),
       matches:$matches,exclusions:($exclusions | sort_by(.path,.operation)),ambiguities:$ambiguities}
    '
)

arkira_route_candidate() (
  local repo=${1:-} base=${2:-} tree=${3:-} floor=${4:-quick} floor_source=${5:-default} exclusions=${6:-}
  local resolved stream empty_exclusions temp
  repo="$(cd -- "$repo" 2>/dev/null && pwd -P)" || { arkira_tier_error 'repository is unavailable'; return 1; }
  resolved="$(git -C "$repo" rev-parse --verify "$base^{commit}" 2>/dev/null)" || { arkira_tier_error 'trusted base is unavailable'; return 1; }
  [[ "$resolved" == "$base" ]] || { arkira_tier_error 'trusted base is ambiguous'; return 1; }
  resolved="$(git -C "$repo" rev-parse --verify "$tree^{tree}" 2>/dev/null)" || { arkira_tier_error 'candidate tree is unavailable'; return 1; }
  [[ "$resolved" == "$tree" ]] || { arkira_tier_error 'candidate tree is ambiguous'; return 1; }
  temp="$(mktemp -d "${TMPDIR:-/tmp}/arkira-tier-candidate.XXXXXX")" || return 1
  trap 'rm -rf -- "$temp"' EXIT
  stream="$temp/diff.raw"
  git -C "$repo" diff-tree -r --no-renames --raw -z "$base" "$tree" > "$stream" || {
    arkira_tier_error 'candidate diff cannot be derived'; return 1; }
  if [[ -z "$exclusions" ]]; then
    empty_exclusions="$temp/exclusions.json"
    printf '[]\n' > "$empty_exclusions" || return 1
    exclusions=$empty_exclusions
  fi
  arkira_tier_route_stream "$repo" "$base" "$tree" "$floor" "$floor_source" "$stream" "$exclusions"
)

arkira_route_tier() (
  local stage=${1:-} current=${2:-} paths_file=${3:-} changed=${4:-0} new_files=${5:-0} legacy_disable=${6:-false}
  local path computed=quick current_rank computed_rank jq_status
  [[ "$stage" == preliminary || "$stage" == post ]] || return 1
  [[ "$changed" =~ ^[0-9]+$ && "$new_files" =~ ^[0-9]+$ ]] || return 1
  [[ "$legacy_disable" == false ]] || return 1
  [[ -z "$current" || "$(arkira_tier_rank "$current")" -gt 0 ]] || return 1
  arkira_tier_policy_valid "$ARKIRA_TIER_ROUTING_POLICY" || return 1
  arkira_tier_nul_stream_complete "$paths_file" || return 1
  while IFS= read -r -d '' path; do
    arkira_tier_path_valid "$path" || return 1
    [[ "$path" != :[0-7][0-7][0-7][0-7][0-7][0-7]' '* ]] || return 1
  done < "$paths_file"
  if jq -ne --rawfile paths "$paths_file" --slurpfile policy "$ARKIRA_TIER_ROUTING_POLICY" \
    "$ARKIRA_TIER_MATCH_JQ"'
      any(($paths | split("\u0000") | .[:-1])[];
        (central_matches(.; "preliminary"; $policy[0]) | length) > 0)
  ' >/dev/null; then
    computed=elevated
  else
    jq_status=$?
    (( jq_status == 1 )) || return "$jq_status"
  fi
  if [[ -n "$current" ]]; then
    current_rank="$(arkira_tier_rank "$current")"; computed_rank="$(arkira_tier_rank "$computed")"
    (( current_rank > computed_rank )) && computed=$current
  fi
  printf '%s' "$computed"
)
