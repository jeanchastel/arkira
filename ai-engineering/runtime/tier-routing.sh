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

arkira_tier_component_tokens() {
  LC_ALL=C sed -E \
    -e 's/([A-Z]+)([A-Z][a-z])|([a-z0-9])([A-Z])/\1\3 \2\4/g' \
    -e 's/[._ -]+/\
/g' \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C awk 'NF {print}'
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

arkira_tier_glob_component_match() {
  local value=$1 pattern=$2
  # shellcheck disable=SC2254  # The validated repository rule is the intended glob pattern.
  case "$value" in $pattern) return 0 ;; *) return 1 ;; esac
}

arkira_tier_glob_match_at() {
  local path_index=$1 pattern_index=$2 path_length=${#ARKIRA_TIER_GLOB_PATH[@]} pattern_length=${#ARKIRA_TIER_GLOB_PATTERN[@]}
  if (( pattern_index == pattern_length )); then
    (( path_index == path_length )); return
  fi
  if [[ "${ARKIRA_TIER_GLOB_PATTERN[$pattern_index]}" == '**' ]]; then
    arkira_tier_glob_match_at "$path_index" "$((pattern_index + 1))" && return 0
    (( path_index < path_length )) || return 1
    arkira_tier_glob_match_at "$((path_index + 1))" "$pattern_index"
    return
  fi
  (( path_index < path_length )) || return 1
  arkira_tier_glob_component_match "${ARKIRA_TIER_GLOB_PATH[$path_index]}" \
    "${ARKIRA_TIER_GLOB_PATTERN[$pattern_index]}" || return 1
  arkira_tier_glob_match_at "$((path_index + 1))" "$((pattern_index + 1))"
}

arkira_tier_glob_match() {
  local path pattern
  path="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  pattern="$(printf '%s' "$2" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  IFS='/' read -r -a ARKIRA_TIER_GLOB_PATH <<< "$path"
  IFS='/' read -r -a ARKIRA_TIER_GLOB_PATTERN <<< "$pattern"
  arkira_tier_glob_match_at 0 0
}

arkira_tier_emit_central_matches() {
  local path=$1 operation=$2 matches=$3 work=$4 component normalized normalized_path token rule_id prefix exact_path index last signal
  local all_tokens="$work/all-tokens" directory_tokens="$work/directory-tokens" filename_tokens="$work/filename-tokens"
  local tokens_json
  local -a components
  : > "$all_tokens"; : > "$directory_tokens"; : > "$filename_tokens"
  normalized_path="$(printf '%s' "$path" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  IFS='/' read -r -a components <<< "$path"
  last=$((${#components[@]} - 1))
  for ((index=0; index<=last; index++)); do
    component=${components[$index]}
    normalized="$(printf '%s' "$component" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    if (( index < last )); then
      printf '%s\n' "$component" | arkira_tier_component_tokens >> "$directory_tokens"
      while IFS= read -r rule_id; do
        [[ -n "$rule_id" ]] || continue
        jq -cn --arg rule_id "$rule_id" --arg path "$path" --arg operation "$operation" \
          --arg matched "$normalized" \
          '{rule_id:$rule_id,source:"central",signal:"directory-component",path:$path,operation:$operation,matched:$matched}' >> "$matches"
      done < <(jq -r --arg term "$normalized" '.directory_rules[] | select(.terms | index($term)) | .id' "$ARKIRA_TIER_ROUTING_POLICY")
    else
      printf '%s\n' "$component" | arkira_tier_component_tokens >> "$filename_tokens"
    fi
  done
  LC_ALL=C sort -u "$directory_tokens" -o "$directory_tokens"
  LC_ALL=C sort -u "$filename_tokens" -o "$filename_tokens"
  { cat "$directory_tokens"; cat "$filename_tokens"; } | LC_ALL=C sort -u > "$all_tokens"
  tokens_json="$(jq -Rn '[inputs]' < "$all_tokens")" || return 1
  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    while IFS= read -r rule_id; do
      [[ -n "$rule_id" ]] || continue
      signal=filename-token
      grep -Fqx -- "$token" "$directory_tokens" && signal=directory-token
      jq -cn --arg rule_id "$rule_id" --arg path "$path" --arg operation "$operation" \
        --arg matched "$token" --arg signal "$signal" --argjson normalized_tokens "$tokens_json" \
        '{rule_id:$rule_id,source:"central",signal:$signal,path:$path,operation:$operation,matched:$matched,normalized_tokens:$normalized_tokens}' >> "$matches"
    done < <(jq -r --arg term "$token" '.token_rules[] | select(.terms | index($term)) | .id' "$ARKIRA_TIER_ROUTING_POLICY")
  done < "$all_tokens"
  while IFS=$'\t' read -r rule_id prefix; do
    [[ -n "$rule_id" && -n "$prefix" ]] || continue
    if [[ "$normalized_path" == "$prefix" || "$normalized_path" == "$prefix/"* ]]; then
      jq -cn --arg rule_id "$rule_id" --arg path "$path" --arg operation "$operation" --arg matched "$prefix" \
        '{rule_id:$rule_id,source:"central",signal:"root-prefix",path:$path,operation:$operation,matched:$matched}' >> "$matches"
    fi
  done < <(jq -r '.root_prefix_rules[] | .id as $id | .prefixes[] | [$id,.] | @tsv' "$ARKIRA_TIER_ROUTING_POLICY")
  while IFS=$'\t' read -r rule_id exact_path; do
    [[ -n "$rule_id" && -n "$exact_path" ]] || continue
    if [[ "$normalized_path" == "$exact_path" ]]; then
      jq -cn --arg rule_id "$rule_id" --arg path "$path" --arg operation "$operation" --arg matched "$exact_path" \
        '{rule_id:$rule_id,source:"central",signal:"exact-path",path:$path,operation:$operation,matched:$matched}' >> "$matches"
    fi
  done < <(jq -r '.exact_path_rules[] | .id as $id | .paths[] | [$id,.] | @tsv' "$ARKIRA_TIER_ROUTING_POLICY")
}

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
          (.verified_harness_sha | type == "string" and test("^[a-f0-9]{40}$")))
      )) and
    ([.[].path] as $paths | ($paths | length) == ($paths | unique | length))
  ' "$exclusions" >/dev/null 2>&1
}

arkira_tier_route_stream() (
  local repo=$1 base=$2 tree=$3 floor=$4 floor_source=$5 stream=$6 exclusions=$7
  local temp policy_digest schema_digest base_manifest candidate_manifest combined_rules operations matches ambiguities
  local exclusions_out metadata old_mode new_mode old_blob new_blob status extra path operation exclusion rule id glob sources
  local final=$floor matches_json ambiguities_json operations_json exclusions_json manifests_json effective_rules_json
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
  operations="$temp/operations.ndjson"; matches="$temp/matches.ndjson"; ambiguities="$temp/ambiguities.ndjson"; exclusions_out="$temp/exclusions.ndjson"
  : > "$operations"; : > "$matches"; : > "$ambiguities"; : > "$exclusions_out"
  while IFS= read -r -d '' metadata; do
    IFS= read -r -d '' path || { arkira_tier_error 'candidate diff stream has an incomplete path record'; return 1; }
    metadata=${metadata#:}
    IFS=' ' read -r old_mode new_mode old_blob new_blob status extra <<< "$metadata"
    [[ -z "${extra:-}" && "$old_mode" =~ ^[0-7]{6}$ && "$new_mode" =~ ^[0-7]{6}$ \
      && "$old_blob" =~ ^[0-9a-f]{40}$ && "$new_blob" =~ ^[0-9a-f]{40}$ \
      && "$status" =~ ^[AMDT]$ ]] || { arkira_tier_error 'candidate diff metadata is malformed or unsupported'; return 1; }
    arkira_tier_path_valid "$path" || { arkira_tier_error 'candidate diff path is malformed'; return 1; }
    case "$status" in A) operation=added ;; M) operation=modified ;; D) operation=deleted ;; T) operation=type-change ;; esac
    jq -cn --arg path "$path" --arg operation "$operation" --arg old_mode "$old_mode" --arg new_mode "$new_mode" \
      --arg old_blob "$old_blob" --arg new_blob "$new_blob" \
      '{path:$path,operation:$operation,old_mode:$old_mode,new_mode:$new_mode,old_blob:$old_blob,new_blob:$new_blob}' >> "$operations"
    exclusion="$(jq -c --arg path "$path" 'first(.[] | select(.path == $path)) // empty' "$exclusions")" || return 1
    if [[ -n "$exclusion" ]]; then
      jq -c --arg operation "$operation" '. + {operation:$operation}' <<< "$exclusion" >> "$exclusions_out" || return 1
      continue
    fi
    arkira_tier_emit_central_matches "$path" "$operation" "$matches" "$temp" || return 1
    while IFS= read -r rule; do
      [[ -n "$rule" ]] || continue
      id="$(jq -r '.id' <<< "$rule")"; glob="$(jq -r '.glob' <<< "$rule")"; sources="$(jq -c '.sources' <<< "$rule")"
      if arkira_tier_glob_match "$path" "$glob"; then
        jq -cn --arg rule_id "$id" --arg path "$path" --arg operation "$operation" --arg matched "$glob" \
          --argjson rule_sources "$sources" \
          '{rule_id:$rule_id,source:"repository",signal:"glob",path:$path,operation:$operation,matched:$matched,rule_sources:$rule_sources}' >> "$matches"
      fi
    done < <(jq -c '.[]' "$combined_rules")
    if [[ "$status" == T ]]; then
      jq -cn --arg path "$path" --arg operation "$operation" \
        '{rule_id:"routing.ambiguous-type-change",path:$path,operation:$operation}' >> "$ambiguities"
    fi
  done < "$stream"
  operations_json="$(jq -s 'sort_by(.path,.operation)' "$operations")" || return 1
  matches_json="$(jq -s 'unique_by([.rule_id,.path,.operation,.signal,.matched]) | sort_by(.path,.rule_id,.signal,.matched)' "$matches")" || return 1
  ambiguities_json="$(jq -s 'unique_by([.rule_id,.path,.operation]) | sort_by(.path,.rule_id)' "$ambiguities")" || return 1
  exclusions_json="$(jq -s 'sort_by(.path,.operation)' "$exclusions_out")" || return 1
  manifests_json="$(jq -s '{base:.[0],candidate:.[1]}' "$base_manifest" "$candidate_manifest")" || return 1
  effective_rules_json="$(jq -c '.' "$combined_rules")" || return 1
  if [[ "$(jq 'length' <<< "$matches_json")" -gt 0 || "$(jq 'length' <<< "$ambiguities_json")" -gt 0 ]]; then
    final=elevated
  fi
  jq -cn --arg final_tier "$final" --arg floor_tier "$floor" --arg floor_source "$floor_source" \
    --arg policy_version "$(jq -r '.policy_version' "$ARKIRA_TIER_ROUTING_POLICY")" \
    --arg policy_digest "$policy_digest" --arg manifest_schema_digest "$schema_digest" \
    --arg trusted_base "$base" --arg candidate_tree "$tree" \
    --argjson manifests "$manifests_json" --argjson effective_rules "$effective_rules_json" \
    --argjson operations "$operations_json" --argjson matches "$matches_json" \
    --argjson exclusions "$exclusions_json" --argjson ambiguities "$ambiguities_json" \
    '{schema_version:1,final_tier:$final_tier,floor:{tier:$floor_tier,source:$floor_source},
      policy:{schema_version:1,version:$policy_version,digest:$policy_digest},
      manifest_schema_digest:$manifest_schema_digest,trusted_base:$trusted_base,candidate_tree:$candidate_tree,
      manifests:$manifests,effective_repository_rules:$effective_rules,operations:$operations,matches:$matches,
      exclusions:$exclusions,ambiguities:$ambiguities}'
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
  local temp matches path computed=quick current_rank computed_rank
  [[ "$stage" == preliminary || "$stage" == post ]] || return 1
  [[ "$changed" =~ ^[0-9]+$ && "$new_files" =~ ^[0-9]+$ ]] || return 1
  [[ "$legacy_disable" == false ]] || return 1
  [[ -z "$current" || "$(arkira_tier_rank "$current")" -gt 0 ]] || return 1
  arkira_tier_policy_valid "$ARKIRA_TIER_ROUTING_POLICY" || return 1
  arkira_tier_nul_stream_complete "$paths_file" || return 1
  temp="$(mktemp -d "${TMPDIR:-/tmp}/arkira-tier-preliminary.XXXXXX")" || return 1
  trap 'rm -rf -- "$temp"' EXIT
  matches="$temp/matches.ndjson"; : > "$matches"
  while IFS= read -r -d '' path; do
    arkira_tier_path_valid "$path" || return 1
    [[ "$path" != :[0-7][0-7][0-7][0-7][0-7][0-7]' '* ]] || return 1
    arkira_tier_emit_central_matches "$path" preliminary "$matches" "$temp" || return 1
  done < "$paths_file"
  [[ -s "$matches" ]] && computed=elevated
  if [[ -n "$current" ]]; then
    current_rank="$(arkira_tier_rank "$current")"; computed_rank="$(arkira_tier_rank "$computed")"
    (( current_rank > computed_rank )) && computed=$current
  fi
  printf '%s' "$computed"
)
