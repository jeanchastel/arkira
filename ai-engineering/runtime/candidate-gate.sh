#!/usr/bin/env bash
# Candidate lifecycle gate. F5 adds validation, F6 adds acceptance, and F7 adds review dispatch.
# ARKIRA_CANDIDATE_GATE_TEST_HOOK is a test-only seam inside the certification
# window. It cannot alter a verdict and runs only before the stability recheck,
# so every mutation it makes is caught before attestation.
set -uo pipefail

ARKIRA_CANDIDATE_GATE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ARKIRA_CANDIDATE_GATE_PRODUCER_DIR="$ARKIRA_CANDIDATE_GATE_DIR"
ARKIRA_CANDIDATE_GATE_BLOCKING_SUITE_IDS=()
ARKIRA_CANDIDATE_GATE_CLASSIFIER_SHAPE=behavioral
ARKIRA_CANDIDATE_GATE_CLASSIFIER_VERSION=null
ARKIRA_CANDIDATE_GATE_CLASSIFIER_RULES=null
ARKIRA_CANDIDATE_GATE_CLASSIFIER_BASE=null
ARKIRA_CANDIDATE_GATE_CLASSIFIER_TREE=null
# shellcheck source=ai-engineering/runtime/role-runtime.sh
. "$ARKIRA_CANDIDATE_GATE_DIR/role-runtime.sh"
# shellcheck source=ai-engineering/runtime/receipt-lib.sh
. "$ARKIRA_CANDIDATE_GATE_DIR/receipt-lib.sh"
# shellcheck source=ai-engineering/runtime/task-contract.sh
. "$ARKIRA_CANDIDATE_GATE_DIR/task-contract.sh"
# shellcheck source=ai-engineering/runtime/preview-run.sh
. "$ARKIRA_CANDIDATE_GATE_DIR/preview-run.sh"

arkira_candidate_gate_error() {
  printf 'candidate gate: %s\n' "$*" >&2
  return 1
}

arkira_candidate_gate_note() {
  printf 'candidate gate: %s\n' "$*" >&2
  return 0
}

arkira_candidate_gate_preview_acceptance() {
  local repo=$1 tree=$2 contract=$3 digest=${4:-} mode target contract_json
  if [[ -f "$contract" && ! -L "$contract" ]]; then
    contract_json="$(jq -c . "$contract")" || return 1
  else
    contract_json="$(jq -c . <<< "$contract")" || return 1
  fi
  mode="$(jq -r 'if .schema_version == 2 then .ui.mode else .ui_policy end' <<< "$contract_json")" || return 1
  [[ "$mode" == local-review ]] || return 0
  arkira_preview_acceptance_valid "$repo" "$tree" || {
    arkira_candidate_gate_error 'local UI review is not accepted for the exact candidate tree'
    return 1
  }
  if [[ -z "$digest" ]]; then
    digest="$(jq -S -c . <<< "$contract_json" | arkira_receipt_sha256)" || return 1
  fi
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
  target="$(arkira_preview_state_dir "$repo")/acceptances/$tree.json"
  jq -e --arg digest "$digest" '.contract_digest == $digest' "$target" >/dev/null 2>&1 || {
    arkira_candidate_gate_error 'local UI acceptance belongs to a different Task contract'
    return 1
  }
}

arkira_candidate_gate_preflight() {
  local repo=$1 base=$2 script resolved status
  # Preflights run from a trusted base extraction, so each script must resolve
  # its own paths instead of deriving them from its script location.
  for script in ai-engineering/scripts/check-version-consistency.sh; do
    resolved="$(arkira_candidate_gate_trusted_script "$repo" "$base" preflight-gates \
      "$(basename -- "$script")" "trusted preflight script $script" "$script")"
    status=$?
    [[ "$status" -ne 4 ]] || continue
    [[ "$status" -eq 0 ]] || return 1
    (cd -- "$repo" && bash "$resolved") || {
      arkira_candidate_gate_error "preflight failed: $script"
      return 1
    }
  done
}

arkira_candidate_gate_residue() {
  local repo=$1 path
  while IFS= read -r -d '' path; do
    arkira_candidate_gate_error "residue: tracked path has unstaged modification: $path"
    return 1
  done < <(git -C "$repo" diff-files --name-only -z)
  while IFS= read -r -d '' path; do
    arkira_candidate_gate_error "residue: untracked path is not ignored: $path"
    return 1
  done < <(git -C "$repo" ls-files --others --exclude-standard -z)
}

arkira_candidate_gate_publication_base() {
  local repo=$1 selected_branch=${2:-} head_branch origin_url='' repo_json pr_base='' pr_head='-'
  local pr_json count base_branch base_sha resolved remote_heads origin_exists=false github_origin=false
  head_branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if origin_url="$(git -C "$repo" config --get remote.origin.url 2>/dev/null)"; then
    origin_exists=true
  fi
  if [[ "$origin_url" =~ ^https://([^/@]+@)?github\.com([/:]|$) \
    || "$origin_url" =~ ^ssh://([^/@]+@)?github\.com([/:]|$) \
    || "$origin_url" =~ ^[^/@:]+@github\.com: ]]; then
    github_origin=true
  fi
  if "$github_origin"; then
    command -v gh >/dev/null 2>&1 || {
      arkira_candidate_gate_error 'gh is required to resolve the publication base'
      return 1
    }
    repo_json="$(cd -- "$repo" && gh repo view --json nameWithOwner 2>/dev/null)" || {
      arkira_candidate_gate_error 'failed to resolve GitHub repository identity'
      return 1
    }
    jq -e '.nameWithOwner | type == "string" and test("^[^/]+/[^/]+$")' <<< "$repo_json" >/dev/null 2>&1 || {
      arkira_candidate_gate_error 'failed to resolve GitHub repository identity'
      return 1
    }
    [[ -n "$head_branch" ]] || {
      arkira_candidate_gate_error 'cannot resolve the publication base from a detached HEAD'
      return 1
    }
    pr_json="$(cd -- "$repo" && gh pr list --head "$head_branch" --state open --json baseRefName,headRefOid)" || return 1
    count="$(jq -er 'if type == "array" then length else error("pull request list is not an array") end' <<< "$pr_json")" || return 1
    (( count <= 1 )) || {
      arkira_candidate_gate_error 'more than one open pull request for the candidate branch'
      return 1
    }
    if (( count == 1 )); then
      pr_base="$(jq -r '.[0].baseRefName // empty' <<< "$pr_json")" || return 1
      pr_head="$(jq -r '.[0].headRefOid // empty' <<< "$pr_json")" || return 1
      [[ "$pr_head" =~ ^[0-9a-f]{40}$ ]] || {
        arkira_candidate_gate_error 'pull request head must be an exact 40 hex commit'
        return 1
      }
    fi
  fi
  if [[ -n "$selected_branch" && -n "$pr_base" && "$selected_branch" != "$pr_base" ]]; then
    arkira_candidate_gate_error 'certified base branch does not match the pull request base branch'
    return 1
  fi
  base_branch=${pr_base:-${selected_branch:-main}}
  [[ "$base_branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$base_branch" != *..* ]] || {
    arkira_candidate_gate_error 'base branch is invalid'
    return 1
  }
  if "$origin_exists"; then
    remote_heads="$(git -C "$repo" ls-remote --heads origin "refs/heads/$base_branch")" || return 1
    base_sha=${remote_heads%%$'\t'*}
    [[ "$remote_heads" == "$base_sha"$'\t'"refs/heads/$base_branch" ]] || {
      arkira_candidate_gate_error 'base branch is unavailable on origin'
      return 1
    }
  else
    base_sha="${ARKIRA_TRUSTED_BASE_SHA:-${VERSION_BASE_REF:-}}"
    if [[ -z "$base_sha" ]]; then
      base_sha="$(git -C "$repo" rev-parse "refs/remotes/origin/$base_branch^{commit}" 2>/dev/null || true)"
    fi
  fi
  [[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || {
    arkira_candidate_gate_error 'trusted base must be an exact 40 hex commit'
    return 1
  }
  resolved="$(git -C "$repo" rev-parse --verify "$base_sha^{commit}" 2>/dev/null)" || {
    arkira_candidate_gate_error 'trusted base does not resolve exactly'
    return 1
  }
  [[ "$resolved" == "$base_sha" ]] || {
    arkira_candidate_gate_error 'trusted base does not resolve exactly'
    return 1
  }
  git -C "$repo" merge-base --is-ancestor "$base_sha" HEAD >/dev/null 2>&1 || {
    arkira_candidate_gate_error 'trusted base is not an ancestor of HEAD'
    return 1
  }
  printf '%s %s %s\n' "$base_branch" "$base_sha" "$pr_head"
}

arkira_candidate_gate_planner_artifact() {
  local path=$1
  case "$path" in
    AGENTS.md|CLAUDE.md|*/AGENTS.md|*/CLAUDE.md) return 1 ;;
    docs/*.md|reports/*.md) return 0 ;;
    __screenshots__/*|*/__screenshots__/*|__snapshots__/*|*/__snapshots__/*|test-results/*|*/test-results/*|playwright-report/*|*/playwright-report/*)
      case "$path" in
        *.png|*.jpg|*.jpeg|*.webp|*.gif|*.zip|*.webm|*.mp4|*.html|*.json|*.txt) return 0 ;;
      esac
      ;;
  esac
  return 1
}

arkira_candidate_gate_executor_required() {
  local repo=$1 revision=$2 source=$3 config value
  if ! git -C "$repo" cat-file -e "${revision}:.arkira/config.json" 2>/dev/null; then
    printf 'false'
    return 0
  fi
  config="$(git -C "$repo" show "${revision}:.arkira/config.json" 2>/dev/null)" || {
    arkira_candidate_gate_error "cannot read $source .arkira/config.json"
    return 1
  }
  value="$(jq -r '
    if type != "object" then error("root")
    elif has("authoring") and (.authoring | type) != "object" then error("authoring")
    elif ((.authoring // {}) | has("executor_required")) and
      ((.authoring.executor_required | type) != "boolean") then error("executor_required")
    else (.authoring.executor_required // false)
    end
  ' <<< "$config" 2>/dev/null)" || {
    arkira_candidate_gate_error "malformed $source .arkira/config.json authoring configuration"
    return 1
  }
  printf '%s' "$value"
}

arkira_candidate_gate_sync_inventory() {
  local entry source target
  ARKIRA_CANDIDATE_GATE_SYNC_SOURCES=()
  ARKIRA_CANDIDATE_GATE_SYNC_TARGETS=()
  # sync-lib is sourced only to independently rebuild the canonical target inventory.
  # shellcheck source=ai-engineering/bootstrap/lib/sync-lib.sh
  . "$ARKIRA_AI_ENGINEERING_DIR/bootstrap/lib/sync-lib.sh"
  for entry in "${SYNC_CHECKS[@]}"; do
    source=${entry%%|*}
    entry=${entry#*|}
    target=${entry%%|*}
    ARKIRA_CANDIDATE_GATE_SYNC_SOURCES+=("$source")
    ARKIRA_CANDIDATE_GATE_SYNC_TARGETS+=("$target")
  done
  # These exact Arkira Sync outputs are reserved outside SYNC_CHECKS. They are
  # not prefixes or globs, so every other .arkira/* path stays outside inventory.
  ARKIRA_CANDIDATE_GATE_SYNC_SOURCES+=("" "")
  ARKIRA_CANDIDATE_GATE_SYNC_TARGETS+=(".arkira/sync-state.json" ".arkira/config.json")
}

arkira_candidate_gate_collect_verified_sync_paths() {
  local repo=$1 candidate_entries_file=$2 snapshot_root path blob mode source candidate index matched
  local snapshot_mode expected_mode trusted_base=${3:-} proven_paths_file=${4:-} installed_sha='' git_root install_record
  local all_proven=true
  [[ -z "$proven_paths_file" ]] || : > "$proven_paths_file" || return 1
  [[ "${ARKIRA_HARNESS_CHANNEL:-}" == installed && "${ARKIRA_HARNESS_VERIFIED:-}" == true ]] || return 1
  [[ -n "${ARKIRA_HARNESS_ROOT:-}" && -d "$ARKIRA_HARNESS_ROOT" && ! -L "$ARKIRA_HARNESS_ROOT" ]] || return 1
  snapshot_root="$(cd -- "$ARKIRA_HARNESS_ROOT" && pwd -P)" || return 1
  [[ "$ARKIRA_AI_ENGINEERING_DIR" == "$snapshot_root/ai-engineering" ]] || return 1
  if [[ -f "$snapshot_root/.arkira-harness-meta.json" && ! -L "$snapshot_root/.arkira-harness-meta.json" ]]; then
    arkira_harness_verify "$snapshot_root" || return 1
    jq -e --arg version "${ARKIRA_HARNESS_VERSION:-}" '
      .schema_version == 1 and .verified == true and .channel == "installed" and
      .version == $version and (.source_sha | test("^[a-f0-9]{40}$"))
    ' "$snapshot_root/.arkira-harness-meta.json" >/dev/null 2>&1 || return 1
    installed_sha="$(jq -r '.source_sha' "$snapshot_root/.arkira-harness-meta.json")" || return 1
  fi
  [[ -f "$snapshot_root/.claude-plugin/plugin.json" && ! -L "$snapshot_root/.claude-plugin/plugin.json" ]] || return 1
  jq -e --arg version "${ARKIRA_HARNESS_VERSION:-}" \
    '.name == "arkira" and .version == $version' \
    "$snapshot_root/.claude-plugin/plugin.json" >/dev/null 2>&1 || return 1
  jq -e 'type == "array"' "$candidate_entries_file" >/dev/null 2>&1 || return 1
  arkira_candidate_gate_sync_inventory || return 1
  while IFS= read -r -d '' path && IFS= read -r -d '' blob && IFS= read -r -d '' mode; do
    if [[ "$mode" != 100644 && "$mode" != 100755 ]]; then
      all_proven=false
      continue
    fi
    case "$path" in
      .arkira/sync-state.json)
        # This is a non-deterministic transformer output with no security-relevant content.
        continue
        ;;
      .arkira/config.json)
        if [[ -z "$trusted_base" || ! "$blob" =~ ^[a-f0-9]{40}([a-f0-9]{24})?$ ]]; then
          all_proven=false
          continue
        fi
        if [[ -z "$installed_sha" ]]; then
          git_root="$(git -C "$snapshot_root" rev-parse --show-toplevel 2>/dev/null || true)"
          if [[ "$git_root" == "$snapshot_root" ]]; then
            if ! installed_sha="$(git -C "$snapshot_root" rev-parse HEAD 2>/dev/null)"; then
              all_proven=false
              continue
            fi
          else
            install_record="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/plugins/installed_plugins.json"
            if ! installed_sha="$(jq -er --arg root "$snapshot_root" --arg version "${ARKIRA_HARNESS_VERSION:-}" '
              first(.plugins["arkira@arkira-labs-standards"][]? |
                select(.installPath == $root and .version == $version) |
                .gitCommitSha | select(type == "string"))
            ' "$install_record" 2>/dev/null)"; then
              all_proven=false
              continue
            fi
          fi
          if [[ ! "$installed_sha" =~ ^[0-9a-f]{40}$ ]]; then
            all_proven=false
            continue
          fi
        fi
        if ! jq -se --arg installed_sha "$installed_sha" '
          def without_sync_fields:
            del(.standards_version) |
            if (.harness | type) == "object" then
              .harness |= del(.pin) |
              if .harness == {} then del(.harness) else . end
            else . end;
          length == 2 and
          (.[0] | type == "object") and
          (.[1] | type == "object") and
          ((.[0] | without_sync_fields) == (.[1] | without_sync_fields)) and
          (.[1] as $candidate |
            if (($candidate.harness | type) == "object" and
              ($candidate.harness | has("pin")) and $candidate.harness.pin != null)
            then $candidate.harness.pin == $installed_sha
            else true
            end)
        ' <(git -C "$repo" show "${trusted_base}:.arkira/config.json") \
          <(git -C "$repo" cat-file blob "$blob") >/dev/null 2>&1; then
          all_proven=false
          continue
        fi
        [[ -z "$proven_paths_file" ]] || printf '%s\0' "$path" >> "$proven_paths_file" || return 1
        continue
        ;;
    esac
    matched=false
    source=''
    for index in "${!ARKIRA_CANDIDATE_GATE_SYNC_TARGETS[@]}"; do
      if [[ "$path" == "${ARKIRA_CANDIDATE_GATE_SYNC_TARGETS[$index]}" ]]; then
        source=${ARKIRA_CANDIDATE_GATE_SYNC_SOURCES[$index]}
        matched=true
        break
      fi
    done
    if ! "$matched"; then
      all_proven=false
      continue
    fi
    if [[ ! "$blob" =~ ^[a-f0-9]{40}([a-f0-9]{24})?$ ]]; then
      all_proven=false
      continue
    fi
    candidate="$snapshot_root/$source"
    if [[ ! -f "$candidate" || -L "$candidate" ]]; then
      all_proven=false
      continue
    fi
    if ! snapshot_mode="$(arkira_safe_file_mode "$snapshot_root" "$source")"; then
      all_proven=false
      continue
    fi
    if [[ ! "$snapshot_mode" =~ ^[0-7]{3,4}$ ]]; then
      all_proven=false
      continue
    fi
    if (( (8#$snapshot_mode & 0111) != 0 )); then
      expected_mode=100755
    else
      expected_mode=100644
    fi
    if [[ "$mode" != "$expected_mode" ]]; then
      all_proven=false
      continue
    fi
    if ! git -C "$repo" cat-file blob "$blob" | cmp -s - "$candidate"; then
      all_proven=false
      continue
    fi
    [[ -z "$proven_paths_file" ]] || printf '%s\0' "$path" >> "$proven_paths_file" || return 1
  done < <(jq -j '.[] | .path, "\u0000", .blob, "\u0000", .mode, "\u0000"' "$candidate_entries_file")
  : "$all_proven"
  return 0
}

arkira_candidate_gate_transformer_receipts_valid() {
  local repo=$1 candidate_entries_file=$2 receipt entry target okay
  arkira_candidate_gate_sync_inventory || return 1
  for receipt in "$(arkira_receipt_store_dir "$repo")"/receipt-*.json; do
    [[ -e "$receipt" ]] || continue
    arkira_receipt_validate "$receipt" || continue
    [[ "$(jq -r '.author_role' "$receipt")" == transformer ]] || continue
    jq -e --slurpfile candidate_entries "$candidate_entries_file" '
      any(.entries[]; . as $receipt_entry |
        any($candidate_entries[0][]; .path == $receipt_entry.path and
          ((.blob == "deleted" and $receipt_entry.deleted == true) or
           (.blob != "deleted" and $receipt_entry.deleted != true and
            .blob == $receipt_entry.blob and .mode == $receipt_entry.mode))))
    ' "$receipt" >/dev/null || continue
    while IFS= read -r entry; do
      okay=false
      for target in "${ARKIRA_CANDIDATE_GATE_SYNC_TARGETS[@]}"; do
        [[ "$entry" == "$target" ]] && { okay=true; break; }
      done
      "$okay" || {
        arkira_candidate_gate_error "transformer receipt names path outside sync inventory: $entry"
        return 1
      }
    done < <(jq -r '.entries[].path' "$receipt")
  done
}

arkira_candidate_gate_build_exclusions() {
  local records=$1 verified_paths=$2 output=$3 harness_sha=${4:-}
  [[ -f "$records" && ! -L "$records" && -f "$verified_paths" && ! -L "$verified_paths" ]] || return 1
  [[ -z "$harness_sha" || "$harness_sha" =~ ^[a-f0-9]{40}$ ]] || return 1
  jq --rawfile verified "$verified_paths" --arg harness_sha "$harness_sha" '
    ($verified | split("\u0000") | map(select(length > 0))) as $paths |
    [.[] |
      select(.path as $path | $paths | index($path)) |
      ([.covering_receipts[]? |
        select(.author_role == "transformer") | .receipt_id] | unique | sort) as $receipt_ids |
      if ($receipt_ids | length > 0) then
        {path,receipt_ids:$receipt_ids}
      elif ($harness_sha | test("^[a-f0-9]{40}$")) then
        {path,verified_harness_sha:$harness_sha}
      else
        error("verified sync path lacks receipt or harness snapshot")
      end] |
    sort_by(.path)
  ' "$records" > "$output" || return 1
  arkira_tier_exclusions_valid "$output"
}

arkira_candidate_gate_final_trigger() {
  local receipt=$1
  jq -er '
    if (.matches | length) > 0 then .matches[0].path
    elif (.ambiguities | length) > 0 then "routing ambiguity: \(.ambiguities[0].path)"
    elif .final_tier != "quick" then "tier floor: \(.floor.source)"
    elif (.operations | length) > 0 and (.exclusions | length) > 0 and
      ([.exclusions[].path] as $excluded |
        ([.operations[].path] - ($excluded + [".arkira/sync-state.json"])) | length == 0) then
      "verified vendored sync"
    else "nothing escalated"
    end
  ' <<< "$receipt"
}

arkira_candidate_gate_collect_coverage_ids() {
  local repo=$1 records record digest receipt_id directory receipt epoch
  records="$(arkira_receipt_covering_records "$@")" || return 1
  [[ -n "$records" ]] || return 0
  while IFS= read -r record; do
    digest="$(jq -r '.contract_digest // empty' <<< "$record")" || return 1
    if [[ -z "$digest" ]]; then
      printf '%s\n' "$record"
      continue
    fi
    receipt_id="$(jq -r '.receipt_id' <<< "$record")" || return 1
    if [[ -z "${directory:-}" ]]; then
      directory="$(arkira_receipt_store_dir "$repo")" || return 1
    fi
    receipt="$directory/$receipt_id.json"
    if ! arkira_receipt_validate "$receipt" ||
      ! epoch="$(jq -er --arg receipt_id "$receipt_id" --arg digest "$digest" '
        select(.receipt_id == $receipt_id and .contract_digest == $digest) | .created_epoch
      ' "$receipt")"; then
      arkira_candidate_gate_error "covering receipt is missing or corrupt: $receipt_id"
      return 1
    fi
    jq -c --argjson created_epoch "$epoch" '. + {created_epoch:$created_epoch}' <<< "$record" || return 1
  done <<< "$records"
}

arkira_candidate_gate_governing_contract() {
  local repo=$1 records=$2 paths=$3 candidates declared_count governing digest contract
  candidates="$(jq -c '
    [.[].covering_receipts[]? | select(.contract_digest != null)] |
    unique_by(.receipt_id) |
    group_by(.contract_digest) |
    map(sort_by(.created_epoch, .receipt_id) | last) |
    sort_by(.created_epoch, .receipt_id) | reverse
  ' "$records")" || return 1
  declared_count="$(jq -r 'length' <<< "$candidates")" || return 1
  [[ "$declared_count" -gt 0 ]] || return 0
  governing="$(jq -c '.[0]' <<< "$candidates")" || return 1
  digest="$(jq -r '.contract_digest' <<< "$governing")" || return 1
  if ! contract="$(arkira_task_contract_load "$repo" "$digest" 2>/dev/null)"; then
    arkira_candidate_gate_error "bound task contract is missing or corrupt for digest: $digest"
    return 1
  fi
  arkira_candidate_gate_scope_authorized "$contract" "$paths" "$digest" || return 1
  jq -cn --arg digest "$digest" --argjson contract "$contract" '{digest:$digest,contract:$contract}'
}

arkira_candidate_gate_scope_authorized() {
  local contract=$1 paths=$2 digest=${3:-} path entry matched
  local -a protected=() allowed=()
  while IFS= read -r entry; do protected+=("$entry"); done < <(jq -r '.scope.protected[]' <<< "$contract")
  while IFS= read -r entry; do allowed+=("$entry"); done < <(jq -r '.scope.allowed[]' <<< "$contract")
  while IFS= read -r -d '' path; do
    for entry in "${protected[@]-}"; do
      if [[ "$path" == "$entry" || "$path" == "$entry/"* ]]; then
        if [[ -n "$digest" ]]; then
          arkira_candidate_gate_error "newest declaring contract $digest does not authorize protected path: $path"
        else
          arkira_candidate_gate_error "protected path in candidate delta: $path"
        fi
        return 1
      fi
    done
  done < "$paths"
  while IFS= read -r -d '' path; do
    case "$path" in
      AGENTS.md|CLAUDE.md|*/AGENTS.md|*/CLAUDE.md) ;;
      docs/*.md|reports/*.md) continue ;;
    esac
    matched=false
    for entry in "${allowed[@]-}"; do
      if [[ "$path" == "$entry" || "$path" == "$entry/"* ]]; then
        matched=true
        break
      fi
    done
    "$matched" || {
      if [[ -n "$digest" ]]; then
        arkira_candidate_gate_error "newest declaring contract $digest does not authorize candidate path: $path"
      else
        arkira_candidate_gate_error "candidate path outside contract scope: $path"
      fi
      return 1
    }
  done < "$paths"
}

arkira_candidate_gate_attestation_dir() {
  local identity=$1 root attestations directory
  root="$(arkira_receipt_runtime_root)"
  attestations="$root/attestations"
  directory="$attestations/$identity"
  [[ ! -L "$root" && ! -L "$attestations" && ! -L "$directory" ]] || return 1
  mkdir -p -- "$directory" || return 1
  [[ -d "$root" && -d "$attestations" && -d "$directory" ]] || return 1
  [[ ! -L "$root" && ! -L "$attestations" && ! -L "$directory" ]] || return 1
  chmod 700 "$root" "$attestations" "$directory" || return 1
  printf '%s' "$directory"
}

arkira_candidate_gate_review_dir() {
  local identity=$1 root reviews directory
  root="$(arkira_receipt_runtime_root)"; reviews="$root/reviews"; directory="$reviews/$identity"
  [[ ! -L "$root" && ! -L "$reviews" && ! -L "$directory" ]] || return 1
  mkdir -p -- "$directory" || return 1
  [[ -d "$root" && -d "$reviews" && -d "$directory" && ! -L "$root" && ! -L "$reviews" && ! -L "$directory" ]] || return 1
  chmod 700 "$root" "$reviews" "$directory" || return 1
  printf '%s' "$directory"
}

arkira_candidate_gate_write_review_record() {
  local repo=$1 base=$2 tree=$3 lineage=$4 provider=$5 model=$6 schema_digest=$7 prompt_digest=$8 duration_seconds=$9 outcome=${10} verdict=${11} findings=${12} response=${13}
  local identity directory response_digest record_id target stage document
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  directory="$(arkira_candidate_gate_review_dir "$identity")" || return 1
  response_digest="$(printf '%s' "$response" | arkira_receipt_sha256)" || return 1
  record_id="$(printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' "$identity" "$base" "$tree" "$lineage" "$provider" "$outcome" "$verdict" "$response_digest" | arkira_receipt_sha256)" || return 1
  target="$directory/$record_id.json"; [[ ! -L "$target" ]] || return 1
  document="$(jq -cn --arg record_id "$record_id" --arg identity "$identity" --arg base "$base" --arg tree "$tree" --arg lineage "$lineage" --arg provider "$provider" --arg model "$model" --arg schema_digest "$schema_digest" --arg prompt_digest "$prompt_digest" --arg outcome "$outcome" --arg verdict "$verdict" --arg response_digest "$response_digest" --argjson duration_seconds "$duration_seconds" --argjson findings "$findings" '{schema_version:1,record_id:$record_id,repo_identity:$identity,trusted_base:$base,candidate_tree:$tree,lineage_id:$lineage,provider:$provider,model:$model,schema_digest:$schema_digest,prompt_contract_digest:$prompt_digest,outcome:$outcome,verdict:(if $verdict == "" then null else $verdict end),findings:$findings,response_digest:$response_digest,duration_seconds:$duration_seconds}')" || return 1
  stage="$(mktemp "$directory/.review.XXXXXX")" || return 1
  printf '%s\n' "$document" > "$stage" || { rm -f -- "$stage"; return 1; }
  chmod 600 "$stage" && mv -f -- "$stage" "$target" || { rm -f -- "$stage"; return 1; }
  printf '%s' "$target"
}

arkira_candidate_gate_test_window() {
  local repo=$1 hook=${ARKIRA_CANDIDATE_GATE_TEST_HOOK:-}
  [[ -z "$hook" ]] && return 0
  [[ -x "$hook" && ! -L "$hook" ]] || return 1
  "$hook" "$repo"
}

arkira_candidate_gate_validation_dir() {
  local identity=$1 root validations directory
  root="$(arkira_receipt_runtime_root)"
  validations="$root/validations"
  directory="$validations/$identity"
  [[ ! -L "$root" && ! -L "$validations" && ! -L "$directory" ]] || return 1
  mkdir -p -- "$directory" || return 1
  [[ -d "$root" && -d "$validations" && -d "$directory" ]] || return 1
  [[ ! -L "$root" && ! -L "$validations" && ! -L "$directory" ]] || return 1
  chmod 700 "$root" "$validations" "$directory" || return 1
  printf '%s' "$directory"
}

arkira_candidate_gate_validation_producer_digest() {
  local path
  for path in \
    "$ARKIRA_CANDIDATE_GATE_PRODUCER_DIR/candidate-gate.sh" \
    "$ARKIRA_CANDIDATE_GATE_PRODUCER_DIR/role-runtime.sh" \
    "$ARKIRA_CANDIDATE_GATE_PRODUCER_DIR/tier-routing.sh" \
    "$ARKIRA_CANDIDATE_GATE_PRODUCER_DIR/receipt-lib.sh" \
    "$ARKIRA_CANDIDATE_GATE_PRODUCER_DIR/task-contract.sh" \
    "$ARKIRA_CANDIDATE_GATE_PRODUCER_DIR/../bootstrap/classify-validation-shape.sh" \
    "$ARKIRA_CANDIDATE_GATE_PRODUCER_DIR/../bootstrap/lib/file-safety.sh" \
    "$ARKIRA_CANDIDATE_GATE_PRODUCER_DIR/../bootstrap/lib/sync-lib.sh"; do
    [[ -f "$path" && ! -L "$path" ]] || return 1
    printf '%s\0' "$path"
    cat -- "$path"
  done | arkira_receipt_sha256
}

arkira_candidate_gate_select_validation_shape() {
  local repo=$1 base=$2 tree=$3 classifier output line key value
  local shape='' version='' rules='' candidate_base='' candidate_tree=''
  local seen_shape=false seen_version=false seen_rules=false seen_base=false seen_tree=false

  ARKIRA_CANDIDATE_GATE_CLASSIFIER_SHAPE=behavioral
  ARKIRA_CANDIDATE_GATE_CLASSIFIER_VERSION=null
  ARKIRA_CANDIDATE_GATE_CLASSIFIER_RULES=null
  ARKIRA_CANDIDATE_GATE_CLASSIFIER_BASE=null
  ARKIRA_CANDIDATE_GATE_CLASSIFIER_TREE=null

  classifier="$ARKIRA_CANDIDATE_GATE_PRODUCER_DIR/../bootstrap/classify-validation-shape.sh"
  [[ -f "$classifier" && ! -L "$classifier" && -x "$classifier" ]] || return 0
  output="$(bash "$classifier" --repo "$repo" --base "$base" --tree "$tree" 2>/dev/null)" || return 0
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || return 0
    key=${line%%=*}; value=${line#*=}
    case "$key" in
      VALIDATION_SHAPE) "$seen_shape" && return 0; seen_shape=true; shape=$value ;;
      CLASSIFIER_VERSION) "$seen_version" && return 0; seen_version=true; version=$value ;;
      CLASSIFIER_RULES) "$seen_rules" && return 0; seen_rules=true; rules=$value ;;
      CANDIDATE_BASE) "$seen_base" && return 0; seen_base=true; candidate_base=$value ;;
      CANDIDATE_TREE) "$seen_tree" && return 0; seen_tree=true; candidate_tree=$value ;;
      *) return 0 ;;
    esac
  done <<< "$output"
  "$seen_shape" && "$seen_version" && "$seen_rules" && "$seen_base" && "$seen_tree" || return 0
  [[ "$shape" == type-only || "$shape" == behavioral ]] || return 0
  [[ "$version" =~ ^[1-9][0-9]*$ && -n "$rules" ]] || return 0
  [[ "$candidate_base" == "$base" && "$candidate_tree" == "$tree" ]] || return 0
  ARKIRA_CANDIDATE_GATE_CLASSIFIER_SHAPE=$shape
  ARKIRA_CANDIDATE_GATE_CLASSIFIER_VERSION=$version
  ARKIRA_CANDIDATE_GATE_CLASSIFIER_RULES="$(jq -Rn --arg value "$rules" '$value')" || return 1
  ARKIRA_CANDIDATE_GATE_CLASSIFIER_BASE="$(jq -Rn --arg value "$candidate_base" '$value')" || return 1
  ARKIRA_CANDIDATE_GATE_CLASSIFIER_TREE="$(jq -Rn --arg value "$candidate_tree" '$value')" || return 1
}

arkira_candidate_gate_focused_dir() {
  local identity=$1 root focused directory
  root="$(arkira_receipt_runtime_root)"
  focused="$root/focused"
  directory="$focused/$identity"
  [[ ! -L "$root" && ! -L "$focused" && ! -L "$directory" ]] || return 1
  mkdir -p -- "$directory" || return 1
  [[ -d "$root" && -d "$focused" && -d "$directory" ]] || return 1
  [[ ! -L "$root" && ! -L "$focused" && ! -L "$directory" ]] || return 1
  chmod 700 "$root" "$focused" "$directory" || return 1
  printf '%s' "$directory"
}

arkira_candidate_gate_focused_check() {
  local repo=$1 base=$2 tree=$3 contract=$4 digest=$5 full_ci=$6 command timeout budget=180 identity directory
  local record_id target stage started duration_seconds status heartbeat heartbeat_owner
  command="$(jq -r '.verification.focused_check' <<< "$contract")" || return 1
  timeout=${ARKIRA_CANDIDATE_GATE_FOCUSED_TIMEOUT_SECONDS:-$budget}
  if [[ ! "$timeout" =~ ^[1-9][0-9]{0,4}$ ]]; then
    arkira_candidate_gate_error 'focused check exceeds the 180 second budget; classify the broader run with --full-ci'
    return 1
  fi
  if (( timeout > budget )) && [[ "$full_ci" != true ]]; then
    arkira_candidate_gate_error 'focused check exceeds the 180 second budget; classify the broader run with --full-ci'
    return 1
  fi
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  directory="$(arkira_candidate_gate_focused_dir "$identity")" || return 1
  record_id="$(printf '%s\0%s\0%s\0%s\0%s\0%s\0' "$identity" "$base" "$tree" "$command" "$digest" "$timeout" | arkira_receipt_sha256)" || return 1
  target="$directory/$record_id.json"
  [[ ! -L "$target" ]] || return 1
  if [[ -f "$target" ]] && jq -e --arg record_id "$record_id" --arg identity "$identity" \
    --arg base "$base" --arg tree "$tree" --arg digest "$digest" --arg command "$command" '
      .record_id == $record_id and .repo_identity == $identity and .trusted_base == $base and
      .candidate_tree == $tree and .contract_digest == $digest and .command == $command and
      .outcome == "passed" and (.duration_seconds | type == "number" and . >= 0)
    ' "$target" >/dev/null 2>&1; then
    ARKIRA_CANDIDATE_GATE_FOCUSED="$(jq -c . "$target")" || return 1
    export ARKIRA_CANDIDATE_GATE_FOCUSED
    duration_seconds="$(jq -r '.duration_seconds' "$target")" || return 1
    arkira_candidate_gate_note "focused check evidence reused (${duration_seconds}s recorded)"
    return 0
  fi
  started=$SECONDS
  if [[ "$timeout" == "$budget" ]]; then
    arkira_candidate_gate_note "focused check started (budget ${budget}s): $command"
  else
    arkira_candidate_gate_note "focused check started (budget ${budget}s, timeout ${timeout}s): $command"
  fi
  heartbeat_owner=$BASHPID
  perl -e '
    use strict;
    use warnings;
    my ($seconds, $owner) = @ARGV;
    my $started = time;
    my $next_report = 30;
    while (1) {
      sleep 1;
      exit 0 if getppid() != $owner;
      my $elapsed = time - $started;
      next if $elapsed < $next_report;
      print STDERR "candidate gate: focused check running (${elapsed}s elapsed of ${seconds}s)\n";
      $next_report += 30 while $elapsed >= $next_report;
    }
  ' "$timeout" "$heartbeat_owner" &
  heartbeat=$!
  if arkira_candidate_gate_run_candidate_command "$repo" "$base" "$command" "$timeout"; then
    status=0
  else
    status=$?
  fi
  kill "$heartbeat" 2>/dev/null || true
  wait "$heartbeat" 2>/dev/null || true
  duration_seconds=$((SECONDS - started))
  if [[ "$status" -eq 14 ]]; then
    arkira_candidate_gate_error "focused check timed out after $timeout seconds: $command"
    return 1
  fi
  if [[ "$status" -ne 0 ]]; then
    arkira_candidate_gate_error "focused check failed (exit status $status)"
    return 1
  fi
  if [[ "$(git -C "$repo" write-tree 2>/dev/null)" != "$tree" ]] || \
    ! arkira_candidate_gate_residue "$repo" >/dev/null 2>&1; then
    arkira_candidate_gate_error 'candidate moved during the focused check'
    return 1
  fi
  stage="$(mktemp "$directory/.focused.XXXXXX")" || return 1
  jq -n --arg record_id "$record_id" --arg repo_identity "$identity" --arg trusted_base "$base" \
    --arg candidate_tree "$tree" --arg contract_digest "$digest" --arg command "$command" \
    --argjson duration_seconds "$duration_seconds" \
    '{record_id:$record_id,repo_identity:$repo_identity,trusted_base:$trusted_base,
      candidate_tree:$candidate_tree,contract_digest:$contract_digest,command:$command,
      outcome:"passed",duration_seconds:$duration_seconds}' > "$stage" || { rm -f -- "$stage"; return 1; }
  if ! chmod 600 "$stage" || ! mv -f -- "$stage" "$target"; then
    rm -f -- "$stage"
    return 1
  fi
  ARKIRA_CANDIDATE_GATE_FOCUSED="$(jq -c . "$target")" || return 1
  export ARKIRA_CANDIDATE_GATE_FOCUSED
  arkira_candidate_gate_note "focused check passed in ${duration_seconds}s"
}

arkira_candidate_gate_active_lineage() {
  local repo=$1 branch=$2 target document
  target="$(arkira_candidate_gate_lineage_path "$repo")" || return 1
  [[ -f "$target" && ! -L "$target" ]] || return 1
  document="$(arkira_candidate_gate_read_lineage "$repo" "$target")" || return 1
  [[ "$(jq -r '.state' <<< "$document")" == open ]] || return 1
  printf '%s' "$(jq -r '.lineage_id' <<< "$document")"
}

arkira_candidate_gate_branch() {
  git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || {
    arkira_candidate_gate_error 'current branch is required for review lineage'
    return 1
  }
}

arkira_candidate_gate_lineage_path() {
  local repo=$1 identity branch hash directory root
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  branch="$(arkira_candidate_gate_branch "$repo")" || return 1
  hash="$(printf '%s' "$branch" | arkira_receipt_sha256)" || return 1
  root="$(arkira_receipt_runtime_root)"; directory="$root/lineages/$identity"
  [[ ! -L "$root" && ! -L "$root/lineages" && ! -L "$directory" ]] || return 1
  mkdir -p -- "$directory" || return 1
  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  chmod 700 "$root" "$root/lineages" "$directory" || return 1
  printf '%s/%s.json' "$directory" "$hash"
}

arkira_candidate_gate_read_lineage() {
  local repo=$1 target=$2 identity branch
  [[ -f "$target" && ! -L "$target" ]] || return 1
  jq -e . "$target" >/dev/null 2>&1 || { arkira_candidate_gate_error 'review lineage is malformed JSON'; return 1; }
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  branch="$(arkira_candidate_gate_branch "$repo")" || return 1
  jq -e --arg identity "$identity" --arg branch "$branch" '
    .schema_version == 1 and (.lineage_id | type == "string" and length > 0) and
    .repo_identity == $identity and .branch == $branch and
    (.base | type == "string" and test("^[a-f0-9]{40}$")) and
    (.dispatches | type == "number" and floor == . and . >= 0) and
    (.grants | type == "number" and floor == . and . >= 0) and
    (.opened | type == "string" and length > 0) and (.state == "open" or .state == "closed")
  ' "$target" >/dev/null || { arkira_candidate_gate_error 'review lineage is malformed for the current branch'; return 1; }
  cat "$target"
}

arkira_candidate_gate_write_lineage() {
  local target=$1 document=$2 directory stage
  directory="$(dirname -- "$target")"
  [[ -d "$directory" && ! -L "$directory" && ! -L "$target" ]] || return 1
  stage="$(mktemp "$directory/.lineage.XXXXXX")" || return 1
  printf '%s\n' "$document" > "$stage" || { rm -f -- "$stage"; return 1; }
  chmod 600 "$stage" && mv -f -- "$stage" "$target" || { rm -f -- "$stage"; return 1; }
}

arkira_candidate_gate_open_lineage() {
  local repo=$1 base=$2 target identity branch id document
  target="$(arkira_candidate_gate_lineage_path "$repo")" || return 1
  if [[ -f "$target" ]]; then
    document="$(arkira_candidate_gate_read_lineage "$repo" "$target")" || return 1
    [[ "$(jq -r '.state' <<< "$document")" == open ]] && { printf '%s' "$document"; return 0; }
  fi
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  branch="$(arkira_candidate_gate_branch "$repo")" || return 1
  id="$(printf '%s\0%s\0%s\0%s' "$identity" "$branch" "$base" "$$-$RANDOM" | arkira_receipt_sha256)" || return 1
  document="$(jq -cn --arg id "$id" --arg identity "$identity" --arg branch "$branch" --arg base "$base" --arg opened "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{schema_version:1,lineage_id:$id,repo_identity:$identity,branch:$branch,base:$base,dispatches:0,grants:0,opened:$opened,state:"open"}')" || return 1
  arkira_candidate_gate_write_lineage "$target" "$document" || return 1
  printf '%s' "$document"
}

arkira_candidate_gate_close_lineage() {
  local repo=$1 target document
  target="$(arkira_candidate_gate_lineage_path "$repo")" || return 1
  [[ -f "$target" ]] || return 0
  document="$(arkira_candidate_gate_read_lineage "$repo" "$target")" || return 1
  [[ "$(jq -r '.state' <<< "$document")" == open ]] || return 0
  document="$(jq -c '.state = "closed"' <<< "$document")" || return 1
  arkira_candidate_gate_write_lineage "$target" "$document"
}

arkira_candidate_gate_lineage_continue() {
  local repo=$1 id=$2 target document confirmation
  target="$(arkira_candidate_gate_lineage_path "$repo")" || return 1
  document="$(arkira_candidate_gate_read_lineage "$repo" "$target")" || return 1
  [[ "$(jq -r '.state' <<< "$document")" == open ]] || { arkira_candidate_gate_error 'review lineage is closed'; return 1; }
  [[ "$(jq -r '.lineage_id' <<< "$document")" == "$id" ]] || { arkira_candidate_gate_error 'review lineage id does not match the current branch'; return 1; }
  printf 'Type continue to grant one additional Verifier dispatch for lineage %s: ' "$id" >&2
  IFS= read -r confirmation || true
  [[ "$confirmation" == continue ]] || { arkira_candidate_gate_error 'confirmation was not affirmative'; return 1; }
  document="$(jq -c '.grants += 1' <<< "$document")" || return 1
  arkira_candidate_gate_write_lineage "$target" "$document"
}

# Only the accepted base can opt a repository into central verification. A
# candidate's config must never select the code that classifies that candidate.
# Status 4 means legacy; all other failures are closed, without a local fallback.
arkira_candidate_gate_central_script() {
  local repo=$1 base=$2 relative=$3 config selection root own script
  if ! git -C "$repo" cat-file -e "$base:.arkira/config.json" 2>/dev/null; then
    return 4
  fi
  config="$(git -C "$repo" show "$base:.arkira/config.json")" || return 3
  selection="$(jq -er 'if (.harness.channel == "stable" and
    .harness.repository == "jeanchastel/arkira")
    then "central" else "legacy" end' <<< "$config")" || return 3
  [[ "$selection" == central ]] || return 4
  [[ "${ARKIRA_HARNESS_VERIFIED:-}" == true && -d "${ARKIRA_HARNESS_ROOT:-}" &&
    ! -L "$ARKIRA_HARNESS_ROOT" ]] || {
    arkira_candidate_gate_error 'central harness selection is not verified'
    return 3
  }
  root="$(cd -- "$ARKIRA_HARNESS_ROOT" && pwd -P)" || return 3
  own="$(cd -- "$ARKIRA_CANDIDATE_GATE_DIR/../.." && pwd -P)" || return 3
  [[ "$root" == "$own" ]] || {
    arkira_candidate_gate_error 'central harness root does not match the running gate'
    return 3
  }
  script="$root/$relative"
  [[ -f "$script" && ! -L "$script" ]] || return 3
  printf '%s' "$script"
}

arkira_candidate_gate_full_gate_command() {
  local repo=$1 tree=$2 base=${3:-$2} central status
  central="$(arkira_candidate_gate_central_script "$repo" "$base" scripts/run-all-tests.sh)"
  status=$?
  if [[ "$status" -eq 0 ]]; then
    printf 'bash %q --mode release --central-product' "$central"
    return 0
  fi
  [[ "$status" -eq 4 ]] || return "$status"
  if git -C "$repo" cat-file -e "$tree:package.json" 2>/dev/null; then
    printf '%s' 'bash scripts/run-product-release-gate.sh'
  else
    printf '%s' 'bash scripts/run-all-tests.sh --mode ci'
  fi
}

arkira_candidate_gate_baseline_command() {
  local repo=$1 tree=$2 harness
  if git -C "$repo" cat-file -e "$tree:ai-engineering/scripts/run-baseline-ci.sh" 2>/dev/null; then
    printf '%s' 'bash ai-engineering/scripts/run-baseline-ci.sh'
  elif git -C "$repo" cat-file -e "$tree:scripts/run-baseline-ci.sh" 2>/dev/null; then
    printf '%s' 'bash scripts/run-baseline-ci.sh'
  else
    harness="$ARKIRA_CANDIDATE_GATE_DIR/../scripts/run-baseline-ci.sh"
    [[ -f "$harness" && ! -L "$harness" ]] || return 1
    harness="$(cd -- "$(dirname -- "$harness")" && pwd -P)/run-baseline-ci.sh" || return 1
    printf 'bash %q' "$harness"
  fi
}

arkira_candidate_gate_dependency_install_command() {
  local repo=$1 tree=$2 base=${3:-$2} entry path central status
  git -C "$repo" cat-file -e "$tree:package.json" 2>/dev/null || return 4
  central="$(arkira_candidate_gate_central_script "$repo" "$base" ai-engineering/scripts/install-product-dependencies.sh)"
  status=$?
  if [[ "$status" -eq 0 ]]; then
    printf 'bash %q' "$central"
    return 0
  fi
  [[ "$status" -eq 4 ]] || return "$status"
  for path in ai-engineering/scripts/install-product-dependencies.sh scripts/install-product-dependencies.sh; do
    entry="$(git -C "$repo" ls-tree "$tree" -- "$path")" || return 1
    [[ -n "$entry" ]] && break
  done
  [[ -n "$entry" ]] || {
    arkira_candidate_gate_error 'package candidate lacks a managed dependency installer'
    return 1
  }
  entry=${entry%%$'\t'*}
  [[ "$entry" == 100755\ blob\ * ]] || {
    arkira_candidate_gate_error 'candidate dependency installer must be a regular executable file'
    return 1
  }
  printf 'bash %s' "$path"
}

arkira_candidate_gate_trusted_script_dir() {
  local identity=$1 blob=$2 collection=$3 root gates repository directory
  root="$(arkira_receipt_runtime_root)"
  gates="$root/$collection"
  repository="$gates/$identity"
  directory="$repository/$blob"
  [[ ! -L "$root" && ! -L "$gates" && ! -L "$repository" && ! -L "$directory" ]] || return 1
  mkdir -p -- "$directory" || return 1
  [[ -d "$root" && -d "$gates" && -d "$repository" && -d "$directory" ]] || return 1
  [[ ! -L "$root" && ! -L "$gates" && ! -L "$repository" && ! -L "$directory" ]] || return 1
  chmod 700 "$root" "$gates" "$repository" "$directory" || return 1
  printf '%s' "$directory"
}

arkira_candidate_gate_trusted_script() {
  local repo=$1 base=$2 collection=$3 target_name=$4 label=$5
  local path entry='' metadata mode kind blob identity directory target stage
  shift 5
  for path in "$@"; do
    entry="$(git -C "$repo" ls-tree "$base" -- "$path" 2>/dev/null)" || entry=''
    if [[ -n "$entry" ]]; then break; fi
  done
  [[ -n "$entry" ]] || return 4
  metadata=${entry%%$'\t'*}
  IFS=' ' read -r mode kind blob <<< "$metadata"
  [[ "$mode" == 100755 && "$kind" == blob && "$blob" =~ ^[0-9a-f]{40}$ ]] || {
    arkira_candidate_gate_error "$label is not a regular executable blob"
    return 3
  }
  identity="$(arkira_receipt_repo_identity "$repo")" || return 3
  directory="$(arkira_candidate_gate_trusted_script_dir "$identity" "$blob" "$collection")" || return 3
  target="$directory/$target_name"
  [[ ! -L "$target" ]] || {
    arkira_candidate_gate_error "$label copy is a symlink"
    return 3
  }
  if [[ ! -f "$target" ]]; then
    stage="$(mktemp "$directory/.gate.XXXXXX")" || return 3
    git -C "$repo" cat-file blob "$blob" > "$stage" || { rm -f -- "$stage"; return 3; }
    chmod 600 "$stage" || { rm -f -- "$stage"; return 3; }
    mv -f -- "$stage" "$target" || { rm -f -- "$stage"; return 3; }
  fi
  printf '%s' "$target"
}

# The gate is resolved from the trusted base and executed from an extracted copy, never from the
# candidate's own tree. A candidate that ships its own gate would otherwise declare itself
# report-only and skip review. The remote lane pins the same way.
arkira_candidate_gate_documentation_script() {
  local repo=$1 base=$2 script status
  script="$(arkira_candidate_gate_central_script "$repo" "$base" ai-engineering/scripts/run-documentation-gate.sh)"
  status=$?
  if [[ "$status" -eq 0 ]]; then
    printf '%s' "$script"
    return 0
  fi
  [[ "$status" -eq 4 ]] || return "$status"
  script="$(arkira_candidate_gate_trusted_script "$repo" "$base" documentation-gates \
    run-documentation-gate.sh 'trusted documentation gate' \
    ai-engineering/scripts/run-documentation-gate.sh scripts/run-documentation-gate.sh)"
  status=$?
  if [[ "$status" -eq 4 ]]; then
    arkira_candidate_gate_error 'documentation gate could not be resolved'
    return 3
  fi
  [[ "$status" -eq 0 ]] || return 3
  printf '%s' "$script"
}

arkira_candidate_gate_report_only() {
  local repo=$1 base=$2 tree=$3 script output resolution_status
  script="$(arkira_candidate_gate_documentation_script "$repo" "$base")"
  resolution_status=$?
  if [[ "$resolution_status" -ne 0 ]]; then
    return 3
  fi
  output="$(bash "$script" classify --repo "$repo" --base "$base" --tree "$tree")" || {
    arkira_candidate_gate_error 'report-only classification failed'
    return 2
  }
  case "$output" in
    VALIDATION_SHAPE=report-only) return 0 ;;
    VALIDATION_SHAPE=complete) return 1 ;;
    *) arkira_candidate_gate_error 'report-only classifier emitted invalid output'; return 2 ;;
  esac
}

arkira_candidate_gate_collect_blocking_suite_ids() {
  local repo=$1 stdout=$2 manifest suite_id known=false existing
  ARKIRA_CANDIDATE_GATE_BLOCKING_SUITE_IDS=()
  manifest="$repo/scripts/test-suites.tsv"
  [[ -r "$manifest" ]] || manifest=/dev/null
  while IFS= read -r suite_id; do
    [[ -n "$suite_id" ]] || continue
    known=false
    if (( ${#ARKIRA_CANDIDATE_GATE_BLOCKING_SUITE_IDS[@]} > 0 )); then
      for existing in "${ARKIRA_CANDIDATE_GATE_BLOCKING_SUITE_IDS[@]}"; do
        [[ "$existing" == "$suite_id" ]] && { known=true; break; }
      done
    fi
    "$known" || ARKIRA_CANDIDATE_GATE_BLOCKING_SUITE_IDS+=("$suite_id")
  done < <(awk -F $'\t' '
    NR == FNR {
      if ($1 != "" && $1 !~ /^#/ && $3 == "required") required[$1] = 1
      next
    }
    NF == 3 && $1 == "RESULT" && $2 != "" && $3 != "" {
      states[++count] = $2
      suites[count] = $3
      next
    }
    /^RELEASE_BLOCKERS=[0-9]+$/ {
      blockers = substr($0, length("RELEASE_BLOCKERS=") + 1)
      blockers_present = 1
    }
    END {
      for (i = 1; i <= count; i++) {
        if (states[i] == "FAIL" || (states[i] == "SKIP" && blockers_present && blockers + 0 > 0 && required[suites[i]])) print suites[i]
      }
    }
  ' "$manifest" "$stdout" 2>/dev/null || true)
}

arkira_candidate_gate_run_candidate_command() {
  local repo=$1 base=$2 command=$3 timeout_seconds=$4 deferred_file=${5:-} capture stdout stderr status parse_status=0
  capture="$(mktemp -d "${TMPDIR:-/tmp}/arkira-candidate-gate.XXXXXX")" || return 1
  stdout="$capture/stdout"
  stderr="$capture/stderr"
  if (cd -- "$repo" && ARKIRA_TRUSTED_BASE_SHA="$base" VERSION_BASE_REF="$base" arkira_run_with_timeout "$stdout" "$stderr" "$timeout_seconds" /dev/null bash -c "$command"); then
    status=0
  else
    status=$?
  fi
  cat "$stdout" "$stderr" >&2 2>/dev/null || true
  arkira_candidate_gate_collect_blocking_suite_ids "$repo" "$stdout"
  if [[ -n "$deferred_file" ]] && ! awk -F $'\t' '
    /^DEFERRED_SUITES=/ { next }
    /^DEFERRED/ {
      if (NF != 4 || $1 != "DEFERRED" || $2 == "" || $3 == "" || $4 == "") exit 1
      print $2 "\t" $3 "\t" $4
    }
  ' "$stdout" > "$deferred_file"; then
    parse_status=1
  fi
  rm -rf -- "$capture"
  [[ "$parse_status" -eq 0 ]] || return 15
  return "$status"
}

arkira_candidate_gate_file_mode() {
  local path=$1 mode
  if mode="$(stat -c '%a' "$path" 2>/dev/null)"; then
    printf '%s' "$mode"
    return 0
  fi
  if mode="$(stat -f '%Lp' "$path" 2>/dev/null)"; then
    printf '%s' "$mode"
    return 0
  fi
  return 1
}

arkira_candidate_gate_run_quick() {
  local repo=$1 base=$2 tree=$3 deferred_file=${4:-} entry mode kind blob path_mode status
  [[ -z "$deferred_file" ]] || : > "$deferred_file" || return 1
  ARKIRA_CANDIDATE_GATE_VALIDATION_SHAPE=minimum-only
  ARKIRA_CANDIDATE_GATE_VALIDATION_COMMAND="git diff --check $base $tree"
  git -C "$repo" diff --check "$base" "$tree" || {
    arkira_candidate_gate_error 'quick diff check failed'
    return 1
  }
  if ! git -C "$repo" cat-file -e "$tree:scripts/quick-gate.sh" 2>/dev/null; then
    [[ ! -e "$repo/scripts/quick-gate.sh" && ! -L "$repo/scripts/quick-gate.sh" ]] || {
      arkira_candidate_gate_error 'quick gate is untracked in the candidate tree'
      return 1
    }
    return 0
  fi
  entry="$(git -C "$repo" ls-tree "$tree" -- scripts/quick-gate.sh)" || return 1
  entry=${entry%%$'\t'*}
  IFS=' ' read -r mode kind blob <<< "$entry"
  [[ "$mode" =~ ^100[0-7][0-7][0-7]$ && "$kind" == blob ]] || {
    arkira_candidate_gate_error 'quick gate is not a regular file in the candidate tree'
    return 1
  }
  [[ -f "$repo/scripts/quick-gate.sh" && ! -L "$repo/scripts/quick-gate.sh" ]] || {
    arkira_candidate_gate_error 'quick gate is not a regular file'
    return 1
  }
  path_mode="$(arkira_candidate_gate_file_mode "$repo/scripts/quick-gate.sh")" || return 1
  (( (0$path_mode & 022) == 0 )) || {
    arkira_candidate_gate_error 'quick gate is writable by group or world'
    return 1
  }
  ARKIRA_CANDIDATE_GATE_VALIDATION_SHAPE=minimum-plus-quick-gate
  ARKIRA_CANDIDATE_GATE_VALIDATION_COMMAND="git diff --check $base $tree; bash scripts/quick-gate.sh"
  if arkira_candidate_gate_run_candidate_command "$repo" "$base" 'bash scripts/quick-gate.sh' "${ARKIRA_CANDIDATE_GATE_QUICK_TIMEOUT_SECONDS:-30}" "$deferred_file"; then
    return 0
  else
    status=$?
  fi
  if [[ "$status" -eq 14 ]]; then
    arkira_candidate_gate_error 'quick gate timed out'
  else
    arkira_candidate_gate_error 'quick gate failed'
  fi
  return 1
}

arkira_candidate_gate_expected_deferred() {
  local repo=$1 tree=$2 profile=$3 shape=$4 output=$5
  : > "$output" || return 1
  [[ "$shape" == full-gate ]] || return 0
  [[ "$profile" == local ]] || return 0
  git -C "$repo" cat-file -e "$tree:scripts/test-suites.tsv" 2>/dev/null || return 0
  git -C "$repo" show "$tree:scripts/test-suites.tsv" |
    awk -F $'\t' '$1 != "" && $1 !~ /^#/ && $3 == "remote-authoritative" { print $1 "\t" $2 "\t" $2 }' |
    LC_ALL=C sort > "$output"
}

arkira_candidate_gate_validation_placeholder() {
  local repo=$1 base=$2 tree=$3 tier=$4 full_ci=${5:-false} report_only=${6:-false} surface_check=${7:-not-applicable} identity lineage='' command='' gate_shape='' gate_mode='' gate_label=full profile=local scope=local-complete script
  local directory record_id target stage status=passed reusable=false expected_file actual_file deferred_json validation_timeout producer_digest dependency_command dependency_status install_dependencies=false smoke_required=true
  ARKIRA_CANDIDATE_GATE_VALIDATION_REUSED=false
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  producer_digest="$(arkira_candidate_gate_validation_producer_digest)" || {
    arkira_candidate_gate_error 'validation producer digest is unavailable'
    return 1
  }
  if [[ "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_SHAPE" == type-only ]] &&
    jq -e '.outcome == "passed"' <<< "${ARKIRA_CANDIDATE_GATE_FOCUSED:-null}" >/dev/null 2>&1; then
    smoke_required=false
  fi
  if lineage="$(arkira_candidate_gate_active_lineage "$repo" "$tree")"; then :; else lineage=''; fi
  [[ "${GITHUB_ACTIONS:-}" == true ]] && profile=github-actions
  directory="$(arkira_candidate_gate_validation_dir "$identity")" || return 1
  expected_file="$(mktemp "$directory/.expected-deferred.XXXXXX")" || return 1
  actual_file="$(mktemp "$directory/.actual-deferred.XXXXXX")" || { rm -f -- "$expected_file"; return 1; }
  if [[ "$report_only" == true ]]; then
    script="$(arkira_candidate_gate_documentation_script "$repo" "$base")" || {
      rm -f -- "$expected_file" "$actual_file"; return 1; }
    printf -v command 'bash %q validate --repo %q --base %q --tree %q' \
      "$script" "$repo" "$base" "$tree"
    gate_shape=report-only
    gate_mode=documentation
    gate_label=documentation
    validation_timeout="${ARKIRA_CANDIDATE_GATE_QUICK_TIMEOUT_SECONDS:-30}"
    : > "$expected_file" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
  elif [[ "$tier" == quick ]]; then
    arkira_candidate_gate_run_quick "$repo" "$base" "$tree" "$actual_file" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
    command=$ARKIRA_CANDIDATE_GATE_VALIDATION_COMMAND
    gate_shape=$ARKIRA_CANDIDATE_GATE_VALIDATION_SHAPE
    gate_mode=quick
    arkira_candidate_gate_expected_deferred "$repo" "$tree" "$profile" "$gate_shape" "$expected_file" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
  elif [[ "$full_ci" == true ]]; then
    command="$(arkira_candidate_gate_full_gate_command "$repo" "$tree" "$base")" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
    gate_shape=full-gate
    gate_mode=release
    validation_timeout="${ARKIRA_CANDIDATE_GATE_FULL_GATE_TIMEOUT_SECONDS:-5100}"
    arkira_candidate_gate_expected_deferred "$repo" "$tree" "$profile" "$gate_shape" "$expected_file" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
    [[ -s "$expected_file" ]] && scope=local-partial
    [[ "$surface_check" != not-applicable ]] || surface_check=full-gate
    install_dependencies=true
  else
    command="git diff --check $base $tree"
    gate_shape=minimum-only
    gate_mode=minimum
    gate_label=minimum
    validation_timeout="${ARKIRA_CANDIDATE_GATE_QUICK_TIMEOUT_SECONDS:-30}"
    : > "$expected_file" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
  fi
  if "$install_dependencies"; then
    dependency_command="$(arkira_candidate_gate_dependency_install_command "$repo" "$tree" "$base")"
    dependency_status=$?
    if [[ "$dependency_status" -eq 0 ]]; then
      command="$dependency_command && $command"
    elif [[ "$dependency_status" -ne 4 ]]; then
      rm -f -- "$expected_file" "$actual_file"
      return 1
    fi
  fi
  [[ "$tier" == quick ]] && validation_timeout="${ARKIRA_CANDIDATE_GATE_QUICK_TIMEOUT_SECONDS:-30}"
  # 3 x 1646 = 4938; max(4938, 1800), rounded up to 300, = 5100.
  record_id="$({ printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' "$identity" "$base" "$tree" "$command" "$profile" "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_SHAPE" "$smoke_required" "$gate_shape" "$gate_mode" "$surface_check" "$producer_digest" "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_VERSION" "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_RULES" "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_BASE" "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_TREE" "${ARKIRA_SUITE_TIMEOUT_SECONDS:-900}" "${ARKIRA_CANDIDATE_GATE_FULL_GATE_TIMEOUT_SECONDS:-5100}" "${ARKIRA_CANDIDATE_GATE_BASELINE_TIMEOUT_SECONDS:-180}" "${ARKIRA_CANDIDATE_GATE_QUICK_TIMEOUT_SECONDS:-30}"; cat "$expected_file"; } | arkira_receipt_sha256)" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
  target="$directory/$record_id.json"
  [[ ! -L "$target" ]] || { rm -f -- "$expected_file" "$actual_file"; return 1; }
  if [[ -f "$target" ]] && jq -e \
    --arg identity "$identity" --arg base "$base" --arg tree "$tree" --arg command "$command" --arg profile "$profile" --arg shape "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_SHAPE" --arg gate_shape "$gate_shape" --arg gate_mode "$gate_mode" \
    --arg producer_digest "$producer_digest" --arg surface_check "$surface_check" --argjson smoke_required "$smoke_required" --arg suite_timeout "${ARKIRA_SUITE_TIMEOUT_SECONDS:-900}" --arg full_gate_timeout "${ARKIRA_CANDIDATE_GATE_FULL_GATE_TIMEOUT_SECONDS:-5100}" --arg baseline_timeout "${ARKIRA_CANDIDATE_GATE_BASELINE_TIMEOUT_SECONDS:-180}" --arg quick_timeout "${ARKIRA_CANDIDATE_GATE_QUICK_TIMEOUT_SECONDS:-30}" \
    --rawfile deferred "$expected_file" \
      '.schema_version == 3 and .outcome == "passed" and .repo_identity == $identity and .trusted_base == $base and .candidate_tree == $tree and .command == $command and .execution_profile == $profile and .shape == $shape and .smoke_required == $smoke_required and .gate_shape == $gate_shape and .gate_mode == $gate_mode and .surface_check == $surface_check and .producer_digest == $producer_digest and .classifier_version != null and .classifier_rules != null and .classifier_base == $base and .classifier_tree == $tree and .suite_timeout_seconds == ($suite_timeout | tonumber) and .full_gate_timeout_seconds == ($full_gate_timeout | tonumber) and .baseline_timeout_seconds == ($baseline_timeout | tonumber) and .quick_timeout_seconds == ($quick_timeout | tonumber) and (.deferred | tojson) == ([ $deferred | split("\n")[] | select(length > 0) | split("\t") | {suite_id:.[0],group:.[1],required_context:.[2]} ] | tojson)' "$target" >/dev/null; then
    reusable=true
  fi
  if "$reusable"; then
    ARKIRA_CANDIDATE_GATE_VALIDATION_RECORD="$(jq -er '.record_id' "$target")" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
    ARKIRA_CANDIDATE_GATE_VALIDATION_COMMAND="$(jq -er '.command' "$target")" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
    ARKIRA_CANDIDATE_GATE_VALIDATION_OUTCOME="$(jq -er '.outcome' "$target")" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
    ARKIRA_CANDIDATE_GATE_VALIDATION_SHAPE="$(jq -er '.shape' "$target")" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
    ARKIRA_CANDIDATE_GATE_VALIDATION_GATE_SHAPE="$(jq -er '.gate_shape' "$target")" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
    ARKIRA_CANDIDATE_GATE_VALIDATION_SURFACE_CHECK="$(jq -er '.surface_check' "$target")" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
    ARKIRA_CANDIDATE_GATE_VALIDATION_SCOPE="$(jq -er '.scope' "$target")" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
    ARKIRA_CANDIDATE_GATE_VALIDATION_DEFERRED="$(jq -ec '.deferred' "$target")" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
    ARKIRA_CANDIDATE_GATE_VALIDATION_REUSED=true
    arkira_candidate_gate_note "$gate_label validation evidence reused: $ARKIRA_CANDIDATE_GATE_VALIDATION_RECORD"
    rm -f -- "$expected_file" "$actual_file"
    return 0
  fi
  if ! "$reusable" && [[ "$tier" != quick || "$report_only" == true ]]; then
    if arkira_candidate_gate_run_candidate_command "$repo" "$base" "$command" "$validation_timeout" "$actual_file"; then :; else
      status=$?
      rm -f -- "$expected_file" "$actual_file"
      if [[ "$status" -eq 14 ]]; then
        arkira_candidate_gate_error "$gate_label gate timed out after consuming $validation_timeout seconds"
      elif [[ "$status" -eq 15 ]]; then
        arkira_candidate_gate_error "$gate_label gate emitted malformed DEFERRED record"
      elif (( ${#ARKIRA_CANDIDATE_GATE_BLOCKING_SUITE_IDS[@]} > 0 )); then
        arkira_candidate_gate_error "$gate_label gate failed: ${ARKIRA_CANDIDATE_GATE_BLOCKING_SUITE_IDS[*]}"
      else
        arkira_candidate_gate_error "$gate_label gate failed (exit status $status)"
      fi
      return 1
    fi
  fi
  if ! "$reusable"; then
    LC_ALL=C sort "$actual_file" -o "$actual_file" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
    if ! cmp -s "$expected_file" "$actual_file"; then
      rm -f -- "$expected_file" "$actual_file"
      arkira_candidate_gate_error "$gate_label gate deferred set does not match candidate manifest"
      return 1
    fi
    if [[ "$(git -C "$repo" write-tree 2>/dev/null)" != "$tree" ]] || \
      ! arkira_candidate_gate_residue "$repo" >/dev/null 2>&1; then
      rm -f -- "$expected_file" "$actual_file"
      arkira_candidate_gate_error 'candidate moved during validation'
      return 1
    fi
  fi
  deferred_json="$(jq -Rn '[inputs | select(length > 0) | split("\t") | {suite_id:.[0],group:.[1],required_context:.[2]}]' < "$expected_file")" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
  stage="$(mktemp "$directory/.validation.XXXXXX")" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
  jq -n --arg record_id "$record_id" --arg repo_identity "$identity" --arg trusted_base "$base" \
    --arg candidate_tree "$tree" --arg command "$command" --arg lineage "$lineage" --arg outcome "$status" \
    --arg shape "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_SHAPE" --arg gate_shape "$gate_shape" --arg gate_mode "$gate_mode" --arg execution_profile "$profile" --arg producer_digest "$producer_digest" --arg scope "$scope" --arg surface_check "$surface_check" \
    --argjson classifier_version "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_VERSION" --argjson classifier_rules "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_RULES" --argjson classifier_base "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_BASE" --argjson classifier_tree "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_TREE" \
    --argjson smoke_required "$smoke_required" \
    --argjson deferred "$deferred_json" --argjson lineage_open "$([[ -n "$lineage" ]] && printf true || printf false)" \
    --argjson suite_timeout_seconds "${ARKIRA_SUITE_TIMEOUT_SECONDS:-900}" --argjson full_gate_timeout_seconds "${ARKIRA_CANDIDATE_GATE_FULL_GATE_TIMEOUT_SECONDS:-5100}" --argjson baseline_timeout_seconds "${ARKIRA_CANDIDATE_GATE_BASELINE_TIMEOUT_SECONDS:-180}" --argjson quick_timeout_seconds "${ARKIRA_CANDIDATE_GATE_QUICK_TIMEOUT_SECONDS:-30}" \
    '{schema_version:3,record_id:$record_id,repo_identity:$repo_identity,trusted_base:$trusted_base,candidate_tree:$candidate_tree,command:$command,lineage:$lineage,lineage_open:$lineage_open,outcome:$outcome,execution_profile:$execution_profile,shape:$shape,smoke_required:$smoke_required,gate_shape:$gate_shape,gate_mode:$gate_mode,classifier_version:$classifier_version,classifier_rules:$classifier_rules,classifier_base:$classifier_base,classifier_tree:$classifier_tree,producer_digest:$producer_digest,suite_timeout_seconds:$suite_timeout_seconds,full_gate_timeout_seconds:$full_gate_timeout_seconds,baseline_timeout_seconds:$baseline_timeout_seconds,quick_timeout_seconds:$quick_timeout_seconds,scope:$scope,deferred:$deferred,surface_check:$surface_check}' > "$stage" || { rm -f -- "$expected_file" "$actual_file"; return 1; }
  chmod 600 "$stage" && mv -f -- "$stage" "$target" || { rm -f -- "$stage" "$expected_file" "$actual_file"; return 1; }
  rm -f -- "$expected_file" "$actual_file"
  ARKIRA_CANDIDATE_GATE_VALIDATION_RECORD="$record_id"
  ARKIRA_CANDIDATE_GATE_VALIDATION_COMMAND="$command"
  ARKIRA_CANDIDATE_GATE_VALIDATION_OUTCOME="$status"
  ARKIRA_CANDIDATE_GATE_VALIDATION_SHAPE="$ARKIRA_CANDIDATE_GATE_CLASSIFIER_SHAPE"
  ARKIRA_CANDIDATE_GATE_VALIDATION_GATE_SHAPE="$gate_shape"
  ARKIRA_CANDIDATE_GATE_VALIDATION_SURFACE_CHECK="$surface_check"
  ARKIRA_CANDIDATE_GATE_VALIDATION_SCOPE="$scope"
  ARKIRA_CANDIDATE_GATE_VALIDATION_DEFERRED="$deferred_json"
  arkira_candidate_gate_note "$gate_label validation evidence recorded: $record_id"
}

arkira_candidate_gate_severity_blocks() {
  local tier=$1 severity=$2
  case "$tier:$severity" in
    quick:P0|normal:P0|normal:P1|elevated:P0|elevated:P1) return 0 ;;
    *) return 1 ;;
  esac
}

arkira_candidate_gate_findings_have_blocking_severity() {
  local tier=$1 findings=$2 severity
  while IFS= read -r severity; do
    arkira_candidate_gate_severity_blocks "$tier" "$severity" && return 0
  done < <(jq -r '.[].severity' <<< "$findings")
  return 1
}

arkira_candidate_gate_mark_pending_host_review() {
  local tree=$1
  ARKIRA_CANDIDATE_GATE_REVIEW="$(jq -cn --arg tree "$tree" '{review_kind:"pending-host-review",candidate_tree:$tree}')" || return 1
  ARKIRA_CANDIDATE_GATE_PENDING_HOST_REVIEW=true
}

arkira_candidate_gate_review_prompt_contract() {
  local base=$1 tree=$2 excluded_count=${3:-0} harness_sha=${4:-}
  printf 'Review the exact candidate below. Base SHA: %s\nCandidate tree SHA: %s\n\n' "$base" "$tree"
  printf 'Direct host authoring is the central default. Do not report absent Executor or Transformer receipts as a finding unless the trusted-base .arkira/config.json sets authoring.executor_required to true.\n\n'
  if [[ "${ARKIRA_HARNESS_CHANNEL:-}" == stable && "${ARKIRA_HARNESS_VERIFIED:-}" == true && "${ARKIRA_HARNESS_ONLINE_VERIFIED:-}" == true ]]; then
    printf 'Verified central-migration trust context: this gate is running from the online-resolved, verified public stable release %s. `harness.channel: stable` with `harness.repository: jeanchastel/arkira`, plus exactly `jeanchastel/arkira/.github/workflows/{validate,cache-warm}.yml@stable`, is the sanctioned first-party control channel. Do not report that exact transition as an unpinned P0 or P1 regression solely because stable advances. Still report any different repository, workflow, ref, third-party floating reference, missing online verification, or loss of project-owned validation.\n\n' "$harness_sha"
  fi
  printf 'For Normal and Elevated candidates, P2 and P3 findings are advisory. Do not return no-go solely because of an advisory finding. A no-go must identify a P0 or P1 finding, or state the separate blocking condition.\n\n'
  if [[ -n "${ARKIRA_CANDIDATE_GATE_REVIEW_TRIGGER:-}" ]]; then
    printf 'Final tier trigger: %s\n' "$ARKIRA_CANDIDATE_GATE_REVIEW_TRIGGER"
    printf 'Enforced surface proof: %s\n\n' "${ARKIRA_CANDIDATE_GATE_REVIEW_SURFACE_CHECK:-not-applicable}"
  fi
  if (( excluded_count > 0 )); then
    printf '%s paths were withheld because they are byte-identical to harness %s. They were reviewed and merged upstream in arkira-labs-standards. Their absence is deliberate rather than an omission. Findings about them are out of scope and must not be raised.\n\n' \
      "$excluded_count" "$harness_sha"
  fi
}

arkira_candidate_gate_review_placeholder() {
  local repo=$1 base=$2 tree=$3 tier=$4 patch=$5 covering_records_file=${6:-/dev/null} excluded_count=${7:-0} harness_sha=${8:-}
  local provider model adapter effort='' schema schema_digest prompt_contract_digest prompt verdict_file output result detail verdict findings lineage target document dispatches grants maximum identity attestation_target started duration_seconds review_record status=0
  local -a dispatch_options=()
  ARKIRA_CANDIDATE_GATE_REVIEW='null'
  ARKIRA_CANDIDATE_GATE_LINEAGE='null'
  ARKIRA_CANDIDATE_GATE_PENDING_HOST_REVIEW=false
  [[ "$tier" == report-only ]] && return 0
  provider="$(ARKIRA_REPO_ROOT="$repo" arkira_resolve_role verifier provider)" || {
    [[ "$tier" == quick ]] && return 0
    [[ "$tier" == normal ]] && { arkira_candidate_gate_mark_pending_host_review "$tree"; return; }
    arkira_candidate_gate_error 'Verifier role cannot be resolved'
    return 1
  }
  if [[ "$provider" == host-session ]]; then
    if [[ "$tier" == elevated ]]; then
      arkira_candidate_gate_error 'Elevated requires a concrete Verifier provider; configure verifier away from host-session'
      return 1
    fi
    [[ "$tier" == quick ]] && return 0
    arkira_candidate_gate_mark_pending_host_review "$tree"
    return
  fi
  if [[ "$tier" == quick || "$tier" == normal ]]; then
    model="$(ARKIRA_REPO_ROOT="$repo" arkira_resolve_role verifier quick_model)" || {
      [[ "$tier" == quick ]] && return 0
      arkira_candidate_gate_mark_pending_host_review "$tree"
      return
    }
    effort=low
    adapter="$(arkira_adapter_file "$provider")" || {
      [[ "$tier" == quick ]] && return 0
      arkira_candidate_gate_mark_pending_host_review "$tree"
      return
    }
    arkira_effort_supported "$adapter" "$effort" || {
      [[ "$tier" == quick ]] && return 0
      arkira_candidate_gate_mark_pending_host_review "$tree"
      return
    }
    dispatch_options=(--model "$model" --effort "$effort")
  else
    model="$(ARKIRA_REPO_ROOT="$repo" arkira_resolve_role verifier model)" || return 1
  fi
  if jq -ne --arg provider "$provider" '[$covering[0][]?.covering_receipts[]? | select(.author_provider == $provider)] | length > 0' \
    --slurpfile covering "$covering_records_file" >/dev/null; then
    arkira_candidate_gate_error "Verifier provider collision with candidate author: $provider"
    return 1
  fi
  schema="$ARKIRA_CANDIDATE_GATE_DIR/schemas/verifier-verdict.json"
  schema_digest="$(arkira_receipt_sha256 < "$schema")" || return 1
  prompt_contract_digest="$(arkira_candidate_gate_review_prompt_contract "$base" "$tree" "$excluded_count" "$harness_sha" | arkira_receipt_sha256)" || return 1
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  attestation_target="$(arkira_candidate_gate_attestation_path "$repo" "$tree")" || return 1
  if [[ -f "$attestation_target" ]]; then
    arkira_candidate_gate_read_attestation "$repo" "$tree" >/dev/null || return 1
    if jq -e \
      --arg identity "$identity" --arg base "$base" --arg tree "$tree" --arg tier "$tier" \
      --arg provider "$provider" --arg model "$model" --arg effort "$effort" --arg schema_digest "$schema_digest" --arg prompt_contract_digest "$prompt_contract_digest" '
        .repo_identity == $identity and .trusted_base == $base and .candidate_tree == $tree and .final_tier == $tier and
        .review.provider == $provider and .review.model == $model and .review.schema_digest == $schema_digest and
        ($effort == "" or .review.effort == $effort) and
        .review.prompt_contract_digest == $prompt_contract_digest and .review.verdict == "go" and
        (.lineage | type == "object")
      ' "$attestation_target" >/dev/null; then
      ARKIRA_CANDIDATE_GATE_REVIEW="$(jq -c '.review' "$attestation_target")" || return 1
      ARKIRA_CANDIDATE_GATE_LINEAGE="$(jq -c '.lineage' "$attestation_target")" || return 1
      return 0
    fi
  fi
  document="$(arkira_candidate_gate_open_lineage "$repo" "$base")" || return 1
  target="$(arkira_candidate_gate_lineage_path "$repo")" || return 1
  dispatches="$(jq -r '.dispatches' <<< "$document")"; grants="$(jq -r '.grants' <<< "$document")"
  maximum=${ARKIRA_MAX_VERIFIER_ROUNDS:-2}
  [[ "$maximum" =~ ^[0-9]+$ ]] || { arkira_candidate_gate_error 'ARKIRA_MAX_VERIFIER_ROUNDS must be a nonnegative integer'; return 1; }
  if [[ "$dispatches" -ge $((1 + maximum + grants)) ]]; then
    arkira_candidate_gate_error 'Verifier dispatch limit reached for this review lineage'
    return 1
  fi
  lineage="$(jq -r '.lineage_id' <<< "$document")"
  prompt="$(mktemp "${TMPDIR:-/tmp}/arkira-verifier-prompt.XXXXXX")" || return 1
  chmod 600 "$prompt"
  { arkira_candidate_gate_review_prompt_contract "$base" "$tree" "$excluded_count" "$harness_sha"; cat "$patch"; } > "$prompt" || { rm -f -- "$prompt"; return 1; }
  started=$SECONDS
  if (( ${#dispatch_options[@]} > 0 )); then
    result="$(ARKIRA_REPO_ROOT="$repo" "$ARKIRA_CANDIDATE_GATE_DIR/role-run.sh" verifier structured_reviewing "${dispatch_options[@]}" --timeout "${ARKIRA_VERIFIER_TIMEOUT_SECONDS:-900}" --prompt-file "$prompt" --schema-file "$schema")" || status=$?
  else
    result="$(ARKIRA_REPO_ROOT="$repo" "$ARKIRA_CANDIDATE_GATE_DIR/role-run.sh" verifier structured_reviewing --timeout "${ARKIRA_VERIFIER_TIMEOUT_SECONDS:-900}" --prompt-file "$prompt" --schema-file "$schema")" || status=$?
  fi
  if (( status != 0 )); then
    duration_seconds=$((SECONDS - started))
    rm -f -- "$prompt"
    [[ "$tier" == quick || "$tier" == normal ]] && return 0
    review_record="$(arkira_candidate_gate_write_review_record "$repo" "$base" "$tree" "$lineage" "$provider" "$model" "$schema_digest" "$prompt_contract_digest" "$duration_seconds" dispatch-failed '' 'null' "$result")" || return 1
    detail="$(jq -r '.error // empty' <<< "$result" 2>/dev/null | tail -c 500)"
    if [[ -n "$detail" ]]; then
      arkira_candidate_gate_error "Verifier dispatch failed closed: $detail; review record: $review_record"
    else
      arkira_candidate_gate_error "Verifier dispatch failed closed; review record: $review_record"
    fi
    return 1
  fi
  duration_seconds=$((SECONDS - started))
  rm -f -- "$prompt"
  output="$(jq -r '.output // empty' <<< "$result")" || { review_record="$(arkira_candidate_gate_write_review_record "$repo" "$base" "$tree" "$lineage" "$provider" "$model" "$schema_digest" "$prompt_contract_digest" "$duration_seconds" malformed '' 'null' "$result")" || return 1; arkira_candidate_gate_error "Verifier response is malformed; review record: $review_record"; return 1; }
  [[ -n "$output" ]] || { review_record="$(arkira_candidate_gate_write_review_record "$repo" "$base" "$tree" "$lineage" "$provider" "$model" "$schema_digest" "$prompt_contract_digest" "$duration_seconds" malformed '' 'null' "$result")" || return 1; arkira_candidate_gate_error "Verifier response is malformed; review record: $review_record"; return 1; }
  verdict_file="$(mktemp "${TMPDIR:-/tmp}/arkira-verdict.XXXXXX")" || return 1
  printf '%s' "$output" > "$verdict_file"
  if ! jq -e . "$verdict_file" >/dev/null 2>&1 || ! arkira_validate_json_schema "$schema" "$verdict_file"; then
    rm -f -- "$verdict_file"
    review_record="$(arkira_candidate_gate_write_review_record "$repo" "$base" "$tree" "$lineage" "$provider" "$model" "$schema_digest" "$prompt_contract_digest" "$duration_seconds" malformed '' 'null' "$output")" || return 1
    arkira_candidate_gate_error "Verifier response is malformed or schema-invalid; review record: $review_record"
    return 1
  fi
  rm -f -- "$verdict_file"
  verdict="$(jq -r '.verdict' <<< "$output")"; findings="$(jq -c '.findings' <<< "$output")"
  review_record="$(arkira_candidate_gate_write_review_record "$repo" "$base" "$tree" "$lineage" "$provider" "$model" "$schema_digest" "$prompt_contract_digest" "$duration_seconds" verdict "$verdict" "$findings" "$output")" || return 1
  document="$(jq -c '.dispatches += 1' <<< "$document")" || return 1
  arkira_candidate_gate_write_lineage "$target" "$document" || return 1
  # Blocking severities are tier-scoped. Both paths use the shared predicate.
  if [[ "$verdict" == go ]] && arkira_candidate_gate_findings_have_blocking_severity "$tier" "$findings"; then
    arkira_candidate_gate_error "Verifier response is contradictory: go includes a blocking finding for $tier: $findings"
    return 1
  fi
  [[ "$verdict" != no-go ]] || { arkira_candidate_gate_error "Verifier returned no-go; review record: $review_record; findings: $findings"; return 1; }
  ARKIRA_CANDIDATE_GATE_REVIEW="$(jq -cn --arg provider "$provider" --arg model "$model" --arg effort "$effort" --arg tree "$tree" --arg verdict "$verdict" --arg schema_digest "$schema_digest" --arg prompt_contract_digest "$prompt_contract_digest" --arg review_record "$review_record" --argjson duration_seconds "$duration_seconds" --argjson findings "$findings" '{review_kind:"verifier-dispatch",provider:$provider,model:$model,candidate_tree:$tree,verdict:$verdict,findings:$findings,schema_digest:$schema_digest,prompt_contract_digest:$prompt_contract_digest,evidence_record:$review_record,duration_seconds:$duration_seconds} + (if $effort == "" then {} else {effort:$effort} end)')"
  ARKIRA_CANDIDATE_GATE_LINEAGE="$(jq -cn --arg id "$lineage" --argjson dispatches "$(jq '.dispatches' <<< "$document")" '{lineage_id:$id,dispatches:$dispatches}')"
}

arkira_candidate_gate_acceptance_dir() {
  local identity=$1 root directory
  root="$(arkira_receipt_runtime_root)"
  directory="$root/acceptances/$identity"
  [[ ! -L "$root" && ! -L "$root/acceptances" && ! -L "$directory" ]] || return 1
  mkdir -p -- "$directory" || return 1
  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  chmod 700 "$root" "$root/acceptances" "$directory" || return 1
  printf '%s' "$directory"
}

arkira_candidate_gate_attestation_path() {
  local repo=$1 tree=$2 identity
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  printf '%s/attestations/%s/%s.json' "$(arkira_receipt_runtime_root)" "$identity" "$tree"
}

arkira_candidate_gate_acceptance_path() {
  local repo=$1 tree=$2 identity
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  printf '%s/acceptances/%s/%s.json' "$(arkira_receipt_runtime_root)" "$identity" "$tree"
}

arkira_candidate_gate_write_attestation() {
  local target=$1 document=$2 directory stage
  directory="$(dirname -- "$target")"
  [[ -f "$target" && ! -L "$target" && ! -L "$directory" ]] || return 1
  stage="$(mktemp "$directory/.attestation-update.XXXXXX")" || return 1
  printf '%s\n' "$document" > "$stage" || { rm -f -- "$stage"; return 1; }
  chmod 600 "$stage" && mv -f -- "$stage" "$target" || { rm -f -- "$stage"; return 1; }
}

arkira_candidate_gate_attestation_structure() {
  jq -e '
    def tier: . == "quick" or . == "normal" or . == "elevated";
    def digest: type == "string" and test("^[a-f0-9]{64}$");
    def object_id: type == "string" and test("^[a-f0-9]{40}$");
    ([.covering_entries[]?.covering_receipts[]? | select(.contract_digest != null)] |
      unique_by(.receipt_id) | sort_by(.created_epoch, .receipt_id)) as $declaring |
    def provenance:
      if (.covering_receipts | length) == 0 then "unattributed"
      elif all(.covering_receipts[]; .author_role == "executor") then "executor"
      elif all(.covering_receipts[]; .author_role == "transformer") then "transformer"
      else "mixed"
      end;
    (.schema_version == 5 or .schema_version == 6) and
    (.repo_identity | type == "string" and test("^[a-f0-9]{64}$")) and
    (.trusted_base_branch | type == "string" and length > 0) and
    (.trusted_base | type == "string" and test("^[a-f0-9]{40}$")) and
    (.publication_head == null or
      (.publication_head | type == "string" and test("^[a-f0-9]{40}$"))) and
    (.candidate_tree | type == "string" and test("^[a-f0-9]{40}$")) and
    (.preliminary_tier | type == "string") and
    (.final_tier | tier) and
    (.final_trigger | type == "string") and (.covering_entries | type == "array") and
    all(.covering_entries[];
      (.path | type == "string" and length > 0) and
      ((.blob == "deleted" and .mode == "deleted") or
        ((.blob | object_id) and (.mode | type == "string" and test("^[0-7]{6}$")))) and
      (.covering_receipts | type == "array") and
      (.provenance_kind == provenance)) and
    (.provenance_summary | type == "object") and
    (.provenance_summary | keys == ["executor","mixed","transformer","unattributed"]) and
    .provenance_summary == {
      unattributed:([.covering_entries[] | select(.provenance_kind == "unattributed")] | length),
      executor:([.covering_entries[] | select(.provenance_kind == "executor")] | length),
      transformer:([.covering_entries[] | select(.provenance_kind == "transformer")] | length),
      mixed:([.covering_entries[] | select(.provenance_kind == "mixed")] | length)
    } and
    (.routing | type == "object") and
    .routing.schema_version == 1 and
    (.routing.final_tier | tier) and .routing.final_tier == .final_tier and
    (.routing.floor.tier | tier) and (.routing.floor.source | type == "string" and length > 0) and
    .routing.policy.schema_version == 1 and
    (.routing.policy.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.routing.policy.digest | digest) and (.routing.manifest_schema_digest | digest) and
    (.routing.trusted_base | object_id) and .routing.trusted_base == .trusted_base and
    (.routing.candidate_tree | object_id) and .routing.candidate_tree == .candidate_tree and
    (.routing.manifests | type == "object") and
    all([.routing.manifests.base,.routing.manifests.candidate][];
      (.source == "base" or .source == "candidate") and (.present | type == "boolean") and
      ((.digest == null and .present == false) or (.digest | digest)) and (.rules | type == "array")) and
    (.routing.effective_repository_rules | type == "array") and
    (.routing.operations | type == "array") and
    all(.routing.operations[];
      (.path | type == "string" and length > 0) and
      (.operation == "added" or .operation == "modified" or .operation == "deleted" or .operation == "type-change") and
      (.old_mode | type == "string" and test("^[0-7]{6}$")) and
      (.new_mode | type == "string" and test("^[0-7]{6}$")) and
      (.old_blob | object_id) and (.new_blob | object_id)) and
    (.routing.matches | type == "array") and
    all(.routing.matches[];
      (.rule_id | type == "string" and length > 0) and (.path | type == "string" and length > 0) and
      (.operation | type == "string" and length > 0) and (.signal | type == "string" and length > 0)) and
    (.routing.exclusions | type == "array") and
    all(.routing.exclusions[];
      (.path | type == "string" and length > 0) and
      (
        ((keys_unsorted | sort) == (["path", "operation", "receipt_ids"] | sort) and
          (.receipt_ids | type == "array" and length > 0) and
          all(.receipt_ids[]; type == "string" and test("^receipt-[0-9]+-[0-9]+-[0-9]+$"))) or
        ((keys_unsorted | sort) == (["path", "operation", "verified_harness_sha"] | sort) and
          (.verified_harness_sha | type == "string" and test("^[a-f0-9]{40}$")))
      )) and
    (.routing.ambiguities | type == "array") and
    (.validation | type == "object") and (.validation.record_id | type == "string") and
    (.validation.command | type == "string") and (.validation.outcome | type == "string") and
    (.validation.shape == "type-only" or .validation.shape == "behavioral") and
    (.validation.gate_shape | type == "string" and length > 0) and
    (.validation.classifier_version == null or (.validation.classifier_version | type == "number" and floor == . and . > 0)) and
    (.validation.classifier_rules == null or (.validation.classifier_rules | type == "string" and length > 0)) and
    (.validation.classifier_base == null or (.validation.classifier_base | object_id)) and
    (.validation.classifier_tree == null or (.validation.classifier_tree | object_id)) and
    ((.validation.classifier_version == null and .validation.classifier_rules == null and .validation.classifier_base == null and .validation.classifier_tree == null) or
      (.validation.classifier_version != null and .validation.classifier_rules != null and .validation.classifier_base == .trusted_base and .validation.classifier_tree == .candidate_tree)) and
    (.validation.smoke_required | type == "boolean") and
    (if .validation.smoke_required == false then
       .validation.shape == "type-only" and .validation.classifier_version != null and
       (.focused_check | type == "object" and .outcome == "passed")
     else true end) and
    (.validation.surface_check | type == "string") and
    (.validation.scope | . == "local-complete" or . == "local-partial") and
    (.validation.deferred | type == "array") and
    (.review.review_kind != "verifier-dispatch" or
      ((.review.schema_digest | type == "string" and test("^[a-f0-9]{64}$")) and
       (.review.prompt_contract_digest | type == "string" and test("^[a-f0-9]{64}$")) and
       (.review.duration_seconds | type == "number" and . >= 0))) and
    (.review.review_kind != "host-record" or
      (.review.candidate_tree == .candidate_tree and (.review.checks | type == "array" and length > 0) and
       all(.review.checks[]; type == "object" and (.outcome | type == "string") and (has("command") or has("name"))))) and
    . as $attestation |
    has("review") and has("acceptance") and has("lineage") and
    (if .schema_version == 6 then
       has("authorization") and
       (.authorization | type == "object" and
        (keys | sort) == ["candidate_tree", "kind", "review_evidence", "validation_record"] and
        .kind == "verified-gates" and
        .candidate_tree == $attestation.candidate_tree and
        .validation_record == $attestation.validation_record and
        .review_evidence == ($attestation.review.evidence_record // null) and
        (if $attestation.final_tier == "elevated" then
           (.review_evidence | type == "string" and length > 0)
         else true
         end))
     else true
     end) and
    all($declaring[]; (.created_epoch | type == "number")) and
    (if ($declaring | length) == 0 then
       (.contract // null) == null and (.focused_check // null) == null
     else
       .contract.digest == $declaring[-1].contract_digest and
       (.contract.objective | type == "string" and length > 0) and
       (.contract.schema_version == 1 or .contract.schema_version == 2) and
       (.contract.scope.allowed | type == "array") and
       (.contract.scope.protected | type == "array") and
       (if .contract.schema_version == 2 then
          (.contract.non_goals | type == "array" and length > 0) and
          (.contract.scope.adopted | type == "array") and
          (.contract.ui | type == "object") and
          (.contract.ui.mode | IN("none","inspect","local-review","browser")) and
          (.contract.ui.dev_command | type == "array") and
          (.contract.ui.review_url | type == "string") and
          (.contract.harness.content_digest | type == "string" and test("^[a-f0-9]{64}$"))
        else true end) and
       (.contract.verification.tier | type == "string" and length > 0) and
       (.contract.verification.focused_check | type == "string" and length > 0) and
       (.contract.harness.sha | type == "string" and length > 0) and
       (.contract.harness.version | type == "string" and length > 0) and
       (.contract.harness.channel | type == "string" and length > 0) and
       (.contract.dispatch.model | type == "string" and length > 0) and
       (.contract.dispatch.effort | type == "string" and length > 0) and
       (.focused_check | type == "object") and
       .focused_check.outcome == "passed" and
       .focused_check.candidate_tree == .candidate_tree and
       .focused_check.trusted_base == .trusted_base and
       .focused_check.repo_identity == .repo_identity and
       .focused_check.contract_digest == .contract.digest and
       .focused_check.command == .contract.verification.focused_check and
       (.focused_check.duration_seconds | type == "number" and . >= 0)
     end)
  ' "$1" >/dev/null 2>&1
}

arkira_candidate_gate_read_attestation() {
  local repo=$1 tree=$2 target identity version current_policy_digest current_schema_digest
  target="$(arkira_candidate_gate_attestation_path "$repo" "$tree")" || return 1
  [[ -f "$target" && ! -L "$target" ]] || { arkira_candidate_gate_error "no attestation for tree: $tree"; return 1; }
  jq -e . "$target" >/dev/null 2>&1 || { arkira_candidate_gate_error 'malformed JSON in attestation'; return 1; }
  version="$(jq -r '.schema_version // empty' "$target")" || return 1
  [[ "$version" != 1 && "$version" != 2 && "$version" != 3 && "$version" != 4 ]] || {
    arkira_candidate_gate_error "attestation schema version $version is not supported; expected version 6"
    return 1
  }
  [[ "$version" == 5 || "$version" == 6 ]] || { arkira_candidate_gate_error 'attestation schema mismatch'; return 1; }
  arkira_candidate_gate_attestation_structure "$target" || { arkira_candidate_gate_error 'attestation missing required field'; return 1; }
  current_policy_digest="$(arkira_tier_policy_digest)" || {
    arkira_candidate_gate_error 'current tier-routing policy is unavailable'
    return 1
  }
  [[ "$(jq -r '.routing.policy.digest' "$target")" == "$current_policy_digest" ]] || {
    arkira_candidate_gate_error 'attestation tier-routing policy is stale'
    return 1
  }
  current_schema_digest="$(arkira_tier_sha256_file "$ARKIRA_TIER_ROUTING_MANIFEST_SCHEMA")" || return 1
  [[ "$(jq -r '.routing.manifest_schema_digest' "$target")" == "$current_schema_digest" ]] || {
    arkira_candidate_gate_error 'attestation risk-path schema is stale'
    return 1
  }
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  [[ "$(jq -r '.repo_identity' "$target")" == "$identity" ]] || { arkira_candidate_gate_error 'attestation for a different repository identity'; return 1; }
  [[ "$(jq -r '.candidate_tree' "$target")" == "$tree" ]] || { arkira_candidate_gate_error 'attestation candidate tree mismatch'; return 1; }
  printf '%s' "$target"
}

arkira_candidate_gate_accept() {
  local repo=$1 tree=$2 identity target acceptance_target confirmation document stage
  repo="$(cd -- "$repo" && pwd -P)" || return 1
  [[ "$tree" =~ ^[a-f0-9]{40}$ ]] || { arkira_candidate_gate_error 'tree must be an exact 40 hex tree'; return 1; }
  target="$(arkira_candidate_gate_read_attestation "$repo" "$tree")" || return 1
  printf 'Type accept to record operator acceptance for tree %s: ' "$tree" >&2
  IFS= read -r confirmation || true
  [[ "$confirmation" == accept ]] || { arkira_candidate_gate_error 'confirmation was not affirmative'; return 1; }
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  acceptance_target="$(arkira_candidate_gate_acceptance_dir "$identity")/$tree.json" || return 1
  stage="$(mktemp "$(dirname -- "$acceptance_target")/.acceptance.XXXXXX")" || return 1
  jq -n --arg repo_identity "$identity" --arg candidate_tree "$tree" '{schema_version:1,repo_identity:$repo_identity,candidate_tree:$candidate_tree,accepted:true}' > "$stage" || return 1
  chmod 600 "$stage" && mv -f -- "$stage" "$acceptance_target" || { rm -f -- "$stage"; return 1; }
  document="$(jq -c --arg repo_identity "$identity" --arg candidate_tree "$tree" '.acceptance = {accepted:true,repo_identity:$repo_identity,candidate_tree:$candidate_tree}' "$target")" || return 1
  arkira_candidate_gate_write_attestation "$target" "$document" || return 1
}

arkira_candidate_gate_record_host_review() {
  local repo=$1 tree=$2 checks=$3 target valid document
  repo="$(cd -- "$repo" && pwd -P)" || return 1
  [[ -f "$checks" && ! -L "$checks" ]] || { arkira_candidate_gate_error 'checks file must be a regular file'; return 1; }
  valid="$(jq -c 'type == "array"' "$checks" 2>/dev/null)" || { arkira_candidate_gate_error 'checks file is not a JSON array'; return 1; }
  [[ "$valid" == true ]] || { arkira_candidate_gate_error 'checks file is not a JSON array'; return 1; }
  valid="$(jq -c 'length > 0' "$checks")" || return 1
  [[ "$valid" == true ]] || { arkira_candidate_gate_error 'checks file array is empty'; return 1; }
  valid="$(jq -c 'all(.[]; type == "object" and (.outcome | type == "string") and (has("command") or has("name")))' "$checks")" || return 1
  [[ "$valid" == true ]] || { arkira_candidate_gate_error 'checks file entry must include a string outcome and command or name'; return 1; }
  target="$(arkira_candidate_gate_read_attestation "$repo" "$tree")" || return 1
  [[ "$(jq -r '.final_tier // empty' "$target")" == normal ]] || { arkira_candidate_gate_error 'host review can only complete a Normal attestation'; return 1; }
  [[ "$(jq -r '.review.review_kind // empty' "$target")" == pending-host-review ]] || { arkira_candidate_gate_error 'host review can only replace a pending-host-review attestation'; return 1; }
  document="$(jq -c --slurpfile checks "$checks" --arg tree "$tree" '.review = {review_kind:"host-record",candidate_tree:$tree,checks:$checks[0]}' "$target")" || return 1
  arkira_candidate_gate_write_attestation "$target" "$document"
}

arkira_candidate_gate_acceptance_matches() {
  local repo=$1 tree=$2 target identity
  target="$(arkira_candidate_gate_acceptance_path "$repo" "$tree")" || return 1
  [[ -f "$target" && ! -L "$target" ]] || return 1
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  jq -e --arg identity "$identity" --arg tree "$tree" '.schema_version == 1 and .repo_identity == $identity and .candidate_tree == $tree and .accepted == true' "$target" >/dev/null 2>&1
}

arkira_candidate_gate_other_acceptance() {
  local repo=$1 tree=$2 identity directory record accepted
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  directory="$(arkira_receipt_runtime_root)/acceptances/$identity"
  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  for record in "$directory"/*.json; do
    [[ -f "$record" && ! -L "$record" ]] || continue
    accepted="$(jq -r '.candidate_tree // empty' "$record" 2>/dev/null)"
    [[ "$accepted" =~ ^[a-f0-9]{40}$ && "$accepted" != "$tree" ]] && return 0
  done
  return 1
}

arkira_candidate_gate_coverage_matches() {
  local repo=$1 base=$2 tree=$3 target=$4 temp coverage matches kind path blob mode current expected
  temp="$(mktemp -d "${TMPDIR:-/tmp}/arkira-candidate-require.XXXXXX")" || return 1
  coverage="$temp/coverage"; git -C "$repo" diff-tree -r --no-renames --raw -z "$base" "$tree" > "$coverage" || { rm -rf -- "$temp"; return 1; }
  matches="$temp/matches"
  jq -jr --rawfile coverage "$coverage" '
    .covering_entries as $covering_entries |
    ($coverage | split("\u0000") | if .[-1] == "" then .[:-1] else . end) as $stream |
    [range(0; ($stream | length); 2) as $index |
      ($stream[$index] | ltrimstr(":") | split(" ")) as $metadata |
      {path:$stream[$index + 1],
       blob:(if $metadata[4] == "D" then "deleted" else $metadata[3] end),
       mode:(if $metadata[4] == "D" then "deleted" else $metadata[1] end)}
    ] as $diff_entries |
    ($diff_entries | map(. as $entry | select(any($covering_entries[]?; .path == $entry.path and .blob == $entry.blob and .mode == $entry.mode) | not)) | .[0]) as $missing |
    if $missing != null then
      "M", "\u0000", $missing.path, "\u0000"
    else
      $diff_entries[] | "C", "\u0000", .path, "\u0000", .blob, "\u0000", .mode, "\u0000"
    end
  ' "$target" > "$matches" || { rm -rf -- "$temp"; return 1; }
  while IFS= read -r -d '' kind; do
    if [[ "$kind" == M ]]; then
      IFS= read -r -d '' path || { rm -rf -- "$temp"; return 1; }
      arkira_candidate_gate_error "coverage mismatch on candidate path: $path"
      rm -rf -- "$temp"
      return 1
    fi
    [[ "$kind" == C ]] || { rm -rf -- "$temp"; return 1; }
    IFS= read -r -d '' path && IFS= read -r -d '' blob && IFS= read -r -d '' mode || { rm -rf -- "$temp"; return 1; }
    current="$temp/current"; expected="$temp/expected"
    arkira_candidate_gate_collect_coverage_ids "$repo" "$path" "$blob" "$mode" |
      jq -S -sc 'sort_by(.receipt_id)' > "$current" || { rm -rf -- "$temp"; return 1; }
    jq -S -c --arg path "$path" --arg blob "$blob" --arg mode "$mode" '
      [.covering_entries[] |
        select(.path == $path and .blob == $blob and .mode == $mode) |
        .covering_receipts[]? |
        . + {contract_digest:(.contract_digest // null)}]
      | sort_by(.receipt_id)
    ' "$target" > "$expected" || { rm -rf -- "$temp"; return 1; }
    if [[ "$(jq -r --arg path "$path" --arg blob "$blob" --arg mode "$mode" '
      first(.covering_entries[] | select(.path == $path and .blob == $blob and .mode == $mode) |
        .provenance_kind)
    ' "$target")" == unattributed ]]; then
      jq -e 'length == 0' "$expected" >/dev/null || { rm -rf -- "$temp"; return 1; }
      jq -e 'all(.[]; .contract_digest == null)' "$current" >/dev/null || { rm -rf -- "$temp"; return 1; }
      continue
    fi
    jq -e -s '
      .[0] as $live | .[1] as $recorded |
      ($recorded | length) > 0 and
      (($recorded - $live) | length) == 0 and
      (([$live[] | select(.contract_digest != null)] | length) == 0 or
       ([$recorded[] | select(.contract_digest != null)] | length) > 0)
    ' "$current" "$expected" >/dev/null || { rm -rf -- "$temp"; return 1; }
  done < "$matches"
  rm -rf -- "$temp"
}

arkira_candidate_gate_review_satisfies_tier() {
  local target=$1 tier=$2 kind verdict
  [[ "$tier" != elevated && "$(jq -r '.validation.shape // empty' "$target")" == report-only ]] \
    && return 0
  kind="$(jq -r '.review.review_kind // empty' "$target")"
  [[ "$kind" != pending-host-review ]] || { arkira_candidate_gate_error 'pending-host-review is provisional; attach the required tree-bound host review with record-host-review'; return 1; }
  if [[ "$tier" == quick ]]; then
    [[ -n "$kind" ]] || return 0
    verdict="$(jq -r '.review.verdict // empty' "$target")"
    [[ "$kind" == verifier-dispatch && "$verdict" == go ]] || { arkira_candidate_gate_error 'Quick requires no review or a go Verifier dispatch'; return 1; }
  elif [[ "$tier" == normal ]]; then
    if [[ "$kind" == verifier-dispatch ]]; then
      verdict="$(jq -r '.review.verdict // empty' "$target")"
      [[ "$verdict" == go ]] || { arkira_candidate_gate_error 'Normal Verifier review must be go'; return 1; }
    elif [[ "$kind" != host-record ]]; then
      arkira_candidate_gate_error 'Normal requires a go Verifier dispatch or a tree-bound host review'
      return 1
    fi
  else
    [[ "$kind" == verifier-dispatch ]] || { arkira_candidate_gate_error 'Elevated requires a concrete dispatched Verifier; a host-review record is insufficient'; return 1; }
  fi
  if arkira_candidate_gate_findings_have_blocking_severity "$tier" "$(jq -c '.review.findings // []' "$target")"; then
    arkira_candidate_gate_error 'unresolved blocking findings for the tier'; return 1
  fi
}

arkira_candidate_gate_require() {
  local repo=$1 mode=$2 tree=${3:-} supplied_base=${4:-} supplied_base_branch=${5:-}
  local target tier schema_version head_tree current_head current_base base_resolution current_base_branch current_pr_head recorded_base recorded_branch recorded_head
  [[ "$mode" == staged || "$mode" == committed || "$mode" == recorded ]] || return 1
  if [[ "$mode" == staged ]]; then tree="$(git -C "$repo" write-tree)" || return 1; fi
  if [[ "$mode" == committed ]]; then tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')" || return 1; fi
  target="$(arkira_candidate_gate_read_attestation "$repo" "$tree")" || {
    if [[ "$mode" == staged ]] && arkira_candidate_gate_other_acceptance "$repo" "$tree"; then
      arkira_candidate_gate_error 'staged tree not equal to accepted tree'
    elif [[ "$mode" == committed ]] && arkira_candidate_gate_other_acceptance "$repo" "$tree"; then
      arkira_candidate_gate_error 'HEAD^{tree} not equal to the accepted tree'
    fi
    return 1
  }
  tier="$(jq -r '.final_tier' "$target")"
  schema_version="$(jq -r '.schema_version' "$target")"
  if [[ "$mode" == staged ]]; then
    arkira_candidate_gate_residue "$repo" || return 1
    arkira_candidate_gate_coverage_matches "$repo" "$(jq -r '.trusted_base' "$target")" "$tree" "$target" || {
      arkira_candidate_gate_error 'coverage mismatch on candidate path'
      return 1
    }
    arkira_candidate_gate_review_satisfies_tier "$target" "$tier" || return 1
    if [[ "$schema_version" == 5 && "$tier" == elevated ]] && ! arkira_candidate_gate_acceptance_matches "$repo" "$tree"; then
      if arkira_candidate_gate_other_acceptance "$repo" "$tree"; then arkira_candidate_gate_error 'staged tree not equal to accepted tree'; else arkira_candidate_gate_error 'missing operator acceptance on legacy Elevated attestation'; fi
      return 1
    fi
    return 0
  fi
  if [[ "$mode" == committed ]]; then
    head_tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')" || return 1
    [[ "$head_tree" == "$tree" ]] || { arkira_candidate_gate_error 'HEAD^{tree} not equal to the accepted tree'; return 1; }
    current_head="$(git -C "$repo" rev-parse HEAD)" || return 1
    arkira_candidate_gate_residue "$repo" || return 1
    recorded_branch="$(jq -r '.trusted_base_branch' "$target")" || return 1
    recorded_base="$(jq -r '.trusted_base' "$target")" || return 1
    recorded_head="$(jq -r '.publication_head // "-"' "$target")" || return 1
    [[ -z "$supplied_base_branch" || "$supplied_base_branch" == "$recorded_branch" ]] || {
      arkira_candidate_gate_error 'supplied base does not match attestation'
      return 1
    }
    [[ -z "$supplied_base" || "$supplied_base" == "$recorded_base" ]] || {
      arkira_candidate_gate_error 'supplied base does not match attestation'
      return 1
    }
    base_resolution="$(arkira_candidate_gate_publication_base "$repo" "$recorded_branch")" || return 1
    read -r current_base_branch current_base current_pr_head <<< "$base_resolution"
    [[ "$current_base_branch" == "$recorded_branch" ]] || { arkira_candidate_gate_error 'trusted base branch no longer current'; return 1; }
    [[ "$current_base" == "$recorded_base" ]] || { arkira_candidate_gate_error 'trusted base no longer current'; return 1; }
    [[ "$current_pr_head" == "$recorded_head" || "$current_pr_head" == "$current_head" ]] || { arkira_candidate_gate_error 'pull request head moved after certification'; return 1; }
  else
    [[ "$(jq -r '.trusted_base' "$target")" == "$supplied_base" ]] || { arkira_candidate_gate_error 'supplied base does not match attestation'; return 1; }
  fi
  arkira_candidate_gate_coverage_matches "$repo" "$(jq -r '.trusted_base' "$target")" "$tree" "$target" || { arkira_candidate_gate_error 'coverage mismatch on candidate path'; return 1; }
  arkira_candidate_gate_review_satisfies_tier "$target" "$tier" || return 1
  if [[ "$schema_version" == 5 && "$tier" == elevated ]] && ! arkira_candidate_gate_acceptance_matches "$repo" "$tree"; then arkira_candidate_gate_error 'missing operator acceptance on legacy Elevated attestation'; return 1; fi
}

arkira_candidate_gate_export_candidate() {
  local repo=$1 tree target
  tree="$(git -C "$repo" write-tree)" || return 1
  target="$(arkira_candidate_gate_read_attestation "$repo" "$tree")" || return 1
  printf '%s %s\n' "$(jq -r '.trusted_base' "$target")" "$tree"
}

arkira_candidate_gate_publication_routing() {
  local repo=$1 supplied_base=${2:-} supplied_base_branch=${3:-} tree target
  arkira_candidate_gate_require "$repo" committed '' "$supplied_base" "$supplied_base_branch" || return 1
  tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')" || return 1
  target="$(arkira_candidate_gate_read_attestation "$repo" "$tree")" || return 1
  jq -c '{final_tier,policy_digest:.routing.policy.digest,floor_source:.routing.floor.source}' "$target"
}

arkira_candidate_gate_certify() (
  local repo=$1 full_ci=${2:-false} selected_branch=${3:-} tree base base_branch pr_head base_resolution identity preliminary=quick final paths coverage review temp status path metadata
  local current_base_branch current_base current_pr_head
  local old_mode new_mode old_blob new_blob covers records_ndjson records final_trigger routing_receipt floor=quick floor_source='preliminary intent'
  local uncovered_index base_executor_required candidate_executor_required executor_required=false provenance_summary
  local governing='' contract='' contract_digest='' contract_tier='' contract_evidence='null'
  local report_only=false classification_status proven verified_paths exclusions excluded_count=0 authored_count=0
  local surface_proof=not-applicable
  local review_scope='null' review_harness_sha='' candidate_path proven_path path_is_proven snapshot_root git_root install_record excluded_paths_json
  local -a proven_paths=() review_paths=() uncovered_paths=()
  repo="$(cd -- "$repo" && pwd -P)" || return 1
  unset ARKIRA_RECEIPT_IDENTITY_REPO ARKIRA_RECEIPT_IDENTITY_VALUE \
    ARKIRA_RECEIPT_IDENTITY_REPO_ARGUMENT ARKIRA_RECEIPT_STORE_IDENTITY ARKIRA_RECEIPT_STORE_DIR
  git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1 || return 1
  arkira_candidate_gate_residue "$repo" || return 1
  tree="$(git -C "$repo" write-tree)" || return 1
  base_resolution="$(arkira_candidate_gate_publication_base "$repo" "$selected_branch")" || return 1
  read -r base_branch base pr_head <<< "$base_resolution"
  base_executor_required="$(arkira_candidate_gate_executor_required "$repo" "$base" 'trusted-base')" || return 1
  candidate_executor_required="$(arkira_candidate_gate_executor_required "$repo" "$tree" candidate)" || return 1
  if [[ "$base_executor_required" == true || "$candidate_executor_required" == true ]]; then
    executor_required=true
  fi
  arkira_candidate_gate_preflight "$repo" "$base" || return 1
  arkira_receipt_repo_identity "$repo" >/dev/null || return 1
  identity=$ARKIRA_RECEIPT_IDENTITY_VALUE
  arkira_receipt_store_dir "$repo" >/dev/null || return 1
  temp="$(mktemp -d "${TMPDIR:-/tmp}/arkira-candidate.XXXXXX")" || return 1
  # The function body is a subshell, so EXIT is the correct scope and fires on normal
  # return and on every error return. It does NOT run if the subshell is terminated by
  # an untrapped signal; no signal cleanup is claimed here.
  trap '[[ -n ${temp:-} ]] && rm -rf -- "$temp"' EXIT
  paths="$temp/paths"; coverage="$temp/coverage"; review="$temp/review.patch"; proven="$temp/proven-paths"
  verified_paths="$temp/verified-sync-paths"; exclusions="$temp/routing-exclusions.json"
  records_ndjson="$temp/covering-records.ndjson"; records="$temp/covering-records.json"
  : > "$records_ndjson" && chmod 600 "$records_ndjson" || return 1
  git -C "$repo" diff-tree -r --no-renames --name-only -z "$base" "$tree" > "$paths" || return 1
  git -C "$repo" diff-tree -r --no-renames --raw -z "$base" "$tree" > "$coverage" || return 1
  git -C "$repo" diff-tree -r --no-renames --patch --full-index "$base" "$tree" > "$review" || return 1
  while IFS= read -r -d '' metadata; do
    IFS= read -r -d '' path || { arkira_candidate_gate_error 'coverage stream has metadata without a path'; return 1; }
    metadata=${metadata#:}
    # shellcheck disable=SC2034  # Old fields are intentionally parsed with the coverage pair.
    IFS=' ' read -r old_mode new_mode old_blob new_blob status <<< "$metadata"
    [[ "$status" =~ ^[AMDT]$ ]] || { arkira_candidate_gate_error "invalid coverage status for $path"; return 1; }
    if [[ "$status" == D ]]; then
      covers="$temp/covers"; arkira_candidate_gate_collect_coverage_ids "$repo" "$path" deleted deleted > "$covers" || return 1
      jq -e -s 'any(.[]; .author_role == "executor" or .author_role == "transformer")' "$covers" >/dev/null ||
        arkira_candidate_gate_planner_artifact "$path" || uncovered_paths+=("$path")
      jq -cn --arg path "$path" --slurpfile covers "$covers" '
        ($covers | map(.author_role) | unique) as $roles |
        {path:$path,blob:"deleted",mode:"deleted",covering_receipts:$covers,
         provenance_kind:(if ($covers | length) == 0 then "unattributed"
           elif $roles == ["executor"] then "executor"
           elif $roles == ["transformer"] then "transformer" else "mixed" end)}
      ' >> "$records_ndjson" || return 1
    else
      covers="$temp/covers"; arkira_candidate_gate_collect_coverage_ids "$repo" "$path" "$new_blob" "$new_mode" > "$covers" || return 1
      jq -e -s 'any(.[]; .author_role == "executor" or .author_role == "transformer")' "$covers" >/dev/null ||
        arkira_candidate_gate_planner_artifact "$path" || uncovered_paths+=("$path")
      jq -cn --arg path "$path" --arg blob "$new_blob" --arg mode "$new_mode" --slurpfile covers "$covers" '
        ($covers | map(.author_role) | unique) as $roles |
        {path:$path,blob:$blob,mode:$mode,covering_receipts:$covers,
         provenance_kind:(if ($covers | length) == 0 then "unattributed"
           elif $roles == ["executor"] then "executor"
           elif $roles == ["transformer"] then "transformer" else "mixed" end)}
      ' >> "$records_ndjson" || return 1
    fi
  done < "$coverage"
  if "$executor_required" && (( ${#uncovered_paths[@]} > 0 )); then
    arkira_candidate_gate_error "authoring.executor_required requires receipt coverage for candidate path: ${uncovered_paths[0]}"
    for ((uncovered_index = 1; uncovered_index < ${#uncovered_paths[@]}; uncovered_index++)); do
      printf '  %s\n' "${uncovered_paths[$uncovered_index]}" >&2
    done
    return 1
  fi
  jq -s . "$records_ndjson" > "$records" || return 1
  chmod 600 "$records" || return 1
  provenance_summary="$(jq -c '{
    unattributed:([.[] | select(.provenance_kind == "unattributed")] | length),
    executor:([.[] | select(.provenance_kind == "executor")] | length),
    transformer:([.[] | select(.provenance_kind == "transformer")] | length),
    mixed:([.[] | select(.provenance_kind == "mixed")] | length)
  }' "$records")" || return 1
  governing="$(arkira_candidate_gate_governing_contract "$repo" "$records" "$paths")" || return 1
  if [[ -n "$governing" ]]; then
    contract_digest="$(jq -r '.digest' <<< "$governing")" || return 1
    contract="$(jq -c '.contract' <<< "$governing")" || return 1
    arkira_candidate_gate_scope_authorized "$contract" "$paths" || return 1
    contract_tier="$(jq -r '.verification.tier' <<< "$contract")" || return 1
    if [[ "$contract_tier" == high-assurance ]]; then
      arkira_candidate_gate_error 'task contract requests an unsupported verification tier: high-assurance'
      return 1
    fi
    [[ "$(arkira_tier_rank "$contract_tier")" -gt 0 ]] || {
      arkira_candidate_gate_error 'task contract requests an invalid verification tier'
      return 1
    }
    if [[ "$(arkira_tier_rank "$contract_tier")" -gt "$(arkira_tier_rank "$floor")" ]]; then
      floor=$contract_tier
      floor_source="task contract: $contract_digest"
    fi
  fi
  arkira_candidate_gate_transformer_receipts_valid "$repo" "$records" || return 1
  if ! arkira_candidate_gate_collect_verified_sync_paths "$repo" "$records" "$base" "$verified_paths"; then
    : > "$verified_paths" || return 1
  fi
  if [[ -s "$verified_paths" ]]; then
    snapshot_root="$(cd -- "$ARKIRA_HARNESS_ROOT" && pwd -P)" || return 1
    git_root="$(git -C "$snapshot_root" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -f "$snapshot_root/.arkira-harness-meta.json" && ! -L "$snapshot_root/.arkira-harness-meta.json" ]]; then
      review_harness_sha="$(jq -er '.source_sha | select(type == "string" and test("^[a-f0-9]{40}$"))' \
        "$snapshot_root/.arkira-harness-meta.json")" || return 1
    elif [[ "$git_root" == "$snapshot_root" ]]; then
      review_harness_sha="$(git -C "$snapshot_root" rev-parse HEAD 2>/dev/null)" || return 1
    else
      install_record="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/plugins/installed_plugins.json"
      review_harness_sha="$(jq -er --arg root "$snapshot_root" --arg version "${ARKIRA_HARNESS_VERSION:-}" '
        first(.plugins["arkira@arkira-labs-standards"][]? |
          select(.installPath == $root and .version == $version) |
          .gitCommitSha | select(type == "string"))
      ' "$install_record" 2>/dev/null)" || return 1
    fi
    [[ "$review_harness_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  fi
  arkira_candidate_gate_build_exclusions "$records" "$verified_paths" "$exclusions" "$review_harness_sha" || return 1
  jq -j '.[] | .path, "\u0000"' "$exclusions" > "$proven" || return 1
  while IFS= read -r -d '' proven_path; do
    proven_paths+=("$proven_path")
  done < "$proven"
  if (( ${#proven_paths[@]} > 0 )); then
    while IFS= read -r -d '' candidate_path; do
      path_is_proven=false
      for proven_path in "${proven_paths[@]}"; do
        if [[ "$candidate_path" == "$proven_path" ]]; then
          path_is_proven=true
          break
        fi
      done
      if ! "$path_is_proven"; then
        review_paths+=("$candidate_path")
        [[ "$candidate_path" == .arkira/sync-state.json ]] || authored_count=$((authored_count + 1))
      fi
    done < "$paths"
  fi
  if (( ${#proven_paths[@]} > 0 )); then
    excluded_count=${#proven_paths[@]}
    excluded_paths_json="$(jq -Rs 'split("\u0000") | map(select(length > 0))' "$proven")" || return 1
    review_scope="$(jq -cn --argjson excluded_paths "$excluded_paths_json" --argjson excluded_count "$excluded_count" \
      --arg harness_sha "$review_harness_sha" \
      '{excluded_paths:$excluded_paths,excluded_count:$excluded_count,harness_sha:$harness_sha}')" || return 1
    if (( ${#review_paths[@]} > 0 )); then
      GIT_LITERAL_PATHSPECS=1 git -C "$repo" diff-tree -r --no-renames --patch --full-index \
        "$base" "$tree" -- "${review_paths[@]}" > "$review" || return 1
    else
      : > "$review" || return 1
    fi
  fi
  routing_receipt="$(arkira_route_candidate "$repo" "$base" "$tree" "$floor" "$floor_source" "$exclusions")" || return 1
  final="$(jq -er '.final_tier' <<< "$routing_receipt")" || return 1
  final_trigger="$(arkira_candidate_gate_final_trigger "$routing_receipt")" || return 1
  arkira_candidate_gate_select_validation_shape "$repo" "$base" "$tree" || return 1
  if [[ "$full_ci" == false && "$final" != elevated ]]; then
    if arkira_candidate_gate_report_only "$repo" "$base" "$tree"; then
      report_only=true
    else
      classification_status=$?
      [[ "$classification_status" -eq 1 || "$classification_status" -eq 3 ]] || return 1
    fi
  fi
  ARKIRA_CANDIDATE_GATE_FOCUSED='null'
  if [[ -n "$contract" ]]; then
    arkira_candidate_gate_focused_check "$repo" "$base" "$tree" "$contract" "$contract_digest" "$full_ci" || return 1
    arkira_candidate_gate_preview_acceptance "$repo" "$tree" "$contract" "$contract_digest" || return 1
    contract_evidence="$(jq -c '{digest} + (.contract | {schema_version,objective,acceptance,non_goals,scope,verification,ui,ui_policy,harness,dispatch})' <<< "$governing")" || return 1
    if [[ "$final" == elevated ]]; then
      surface_proof="$(jq -er '.verification.focused_check | select(type == "string" and length > 0)' \
        <<< "$contract")" || return 1
    fi
  fi
  arkira_candidate_gate_validation_placeholder "$repo" "$base" "$tree" "$final" "$full_ci" "$report_only" "$surface_proof" || return 1
  local smoke_required=true
  if [[ "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_SHAPE" == type-only ]] &&
    jq -e '.outcome == "passed"' <<< "$ARKIRA_CANDIDATE_GATE_FOCUSED" >/dev/null 2>&1; then
    smoke_required=false
  fi
  ARKIRA_CANDIDATE_GATE_REVIEW_TRIGGER="$final_trigger"
  ARKIRA_CANDIDATE_GATE_REVIEW_SURFACE_CHECK="$ARKIRA_CANDIDATE_GATE_VALIDATION_SURFACE_CHECK"
  if "$report_only"; then
    arkira_candidate_gate_review_placeholder "$repo" "$base" "$tree" report-only "$review" "$records" "$excluded_count" "$review_harness_sha" || return 1
  else
    arkira_candidate_gate_review_placeholder "$repo" "$base" "$tree" "$final" "$review" "$records" "$excluded_count" "$review_harness_sha" || return 1
  fi
  arkira_candidate_gate_test_window "$repo" || { arkira_candidate_gate_error 'certification test window failed'; return 1; }
  [[ "$(git -C "$repo" write-tree)" == "$tree" ]] || { arkira_candidate_gate_error 'candidate tree moved before attestation'; return 1; }
  arkira_candidate_gate_residue "$repo" || { arkira_candidate_gate_error 'residue moved before attestation'; return 1; }
  [[ "$(arkira_receipt_repo_identity_fresh "$repo")" == "$identity" ]] || { arkira_candidate_gate_error 'repository identity moved before attestation'; return 1; }
  base_resolution="$(arkira_candidate_gate_publication_base "$repo" "$selected_branch")" || return 1
  read -r current_base_branch current_base current_pr_head <<< "$base_resolution"
  [[ "$current_base_branch" == "$base_branch" && "$current_base" == "$base" ]] || { arkira_candidate_gate_error 'trusted base moved before attestation'; return 1; }
  [[ "$current_pr_head" == "$pr_head" ]] || { arkira_candidate_gate_error 'pull request head moved before attestation'; return 1; }
  local directory target stage
  directory="$(arkira_candidate_gate_attestation_dir "$identity")" || return 1
  target="$directory/$tree.json"; [[ ! -L "$target" ]] || { arkira_candidate_gate_error 'attestation target is a symlink'; return 1; }
  stage="$(mktemp "$directory/.attestation.XXXXXX")" || return 1
  jq -n --arg repo_identity "$identity" --arg trusted_base_branch "$base_branch" \
    --arg trusted_base "$base" --arg publication_head "$pr_head" --arg candidate_tree "$tree" \
    --arg preliminary_tier "$preliminary" --arg final_tier "$final" --arg final_trigger "$final_trigger" \
    --arg validation_record "$ARKIRA_CANDIDATE_GATE_VALIDATION_RECORD" \
    --arg validation_command "$ARKIRA_CANDIDATE_GATE_VALIDATION_COMMAND" \
    --arg validation_outcome "$ARKIRA_CANDIDATE_GATE_VALIDATION_OUTCOME" \
    --arg validation_shape "$ARKIRA_CANDIDATE_GATE_VALIDATION_SHAPE" \
    --arg validation_gate_shape "$ARKIRA_CANDIDATE_GATE_VALIDATION_GATE_SHAPE" \
    --arg validation_scope "$ARKIRA_CANDIDATE_GATE_VALIDATION_SCOPE" \
    --arg validation_surface_check "$ARKIRA_CANDIDATE_GATE_VALIDATION_SURFACE_CHECK" \
    --argjson classifier_version "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_VERSION" \
    --argjson classifier_rules "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_RULES" \
    --argjson classifier_base "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_BASE" \
    --argjson classifier_tree "$ARKIRA_CANDIDATE_GATE_CLASSIFIER_TREE" \
    --argjson smoke_required "$smoke_required" \
    --argjson validation_deferred "$ARKIRA_CANDIDATE_GATE_VALIDATION_DEFERRED" \
    --argjson routing_receipt "$routing_receipt" --argjson contract_evidence "$contract_evidence" --argjson focused_check "$ARKIRA_CANDIDATE_GATE_FOCUSED" --argjson review_scope "$review_scope" \
    --slurpfile entries "$records" --argjson provenance_summary "$provenance_summary" --argjson review "$ARKIRA_CANDIDATE_GATE_REVIEW" --argjson lineage "$ARKIRA_CANDIDATE_GATE_LINEAGE" \
    '{schema_version:6,repo_identity:$repo_identity,trusted_base_branch:$trusted_base_branch,trusted_base:$trusted_base,publication_head:(if $publication_head == "-" then null else $publication_head end),candidate_tree:$candidate_tree,preliminary_tier:$preliminary_tier,final_tier:$final_tier,final_trigger:$final_trigger,routing:$routing_receipt,covering_entries:$entries[0],provenance_summary:$provenance_summary,contract:$contract_evidence,focused_check:$focused_check,validation_record:$validation_record,validation:{record_id:$validation_record,command:$validation_command,outcome:$validation_outcome,shape:$validation_shape,gate_shape:$validation_gate_shape,classifier_version:$classifier_version,classifier_rules:$classifier_rules,classifier_base:$classifier_base,classifier_tree:$classifier_tree,smoke_required:$smoke_required,scope:$validation_scope,deferred:$validation_deferred,surface_check:$validation_surface_check,tests_executed_by:"gate"},review_scope:$review_scope,review:$review,authorization:{kind:"verified-gates",candidate_tree:$candidate_tree,validation_record:$validation_record,review_evidence:($review.evidence_record // null)},acceptance:null,lineage:$lineage}' > "$stage" || return 1
  chmod 600 "$stage" && mv -f -- "$stage" "$target" || { rm -f -- "$stage"; return 1; }
  [[ "$report_only" == true ]] || arkira_candidate_gate_close_lineage "$repo" || return 1
  printf '%s\n' "$target"
  if [[ "${ARKIRA_CANDIDATE_GATE_PENDING_HOST_REVIEW:-false}" == true ]]; then
    printf 'candidate gate: review is still required; attach it with: %s record-host-review --repo %q --tree %q --checks <checks.json>\n' "$ARKIRA_CANDIDATE_GATE_DIR/candidate-gate.sh" "$repo" "$tree" >&2
    return 20
  fi
)

arkira_candidate_gate_validate() (
  local repo=$1 selected_branch=${2:-} tree base base_branch pr_head base_resolution identity
  local current_base_branch current_base current_pr_head
  repo="$(cd -- "$repo" && pwd -P)" || return 1
  unset ARKIRA_RECEIPT_IDENTITY_REPO ARKIRA_RECEIPT_IDENTITY_VALUE \
    ARKIRA_RECEIPT_IDENTITY_REPO_ARGUMENT ARKIRA_RECEIPT_STORE_IDENTITY ARKIRA_RECEIPT_STORE_DIR
  git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1 || return 1
  arkira_candidate_gate_residue "$repo" || return 1
  tree="$(git -C "$repo" write-tree)" || return 1
  base_resolution="$(arkira_candidate_gate_publication_base "$repo" "$selected_branch")" || return 1
  read -r base_branch base pr_head <<< "$base_resolution"
  arkira_candidate_gate_preflight "$repo" "$base" || return 1
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  arkira_candidate_gate_select_validation_shape "$repo" "$base" "$tree" || return 1
  arkira_candidate_gate_validation_placeholder "$repo" "$base" "$tree" normal true false || return 1
  [[ "$(git -C "$repo" write-tree)" == "$tree" ]] || {
    arkira_candidate_gate_error 'candidate tree moved during validation'
    return 1
  }
  arkira_candidate_gate_residue "$repo" || return 1
  [[ "$(arkira_receipt_repo_identity_fresh "$repo")" == "$identity" ]] || {
    arkira_candidate_gate_error 'repository identity moved during validation'
    return 1
  }
  base_resolution="$(arkira_candidate_gate_publication_base "$repo" "$selected_branch")" || return 1
  read -r current_base_branch current_base current_pr_head <<< "$base_resolution"
  [[ "$current_base_branch" == "$base_branch" && "$current_base" == "$base" && "$current_pr_head" == "$pr_head" ]] || {
    arkira_candidate_gate_error 'trusted base moved during validation'
    return 1
  }
  printf 'validation record: %s (%s)\n' "$ARKIRA_CANDIDATE_GATE_VALIDATION_RECORD" \
    "$([[ "$ARKIRA_CANDIDATE_GATE_VALIDATION_REUSED" == true ]] && printf reused || printf recorded)"
)

arkira_candidate_gate_main() {
  local command=${1:-} repo='' tree='' checks='' candidate_tree='' base='' base_branch='' id='' full_ci=false
  local publication_resolution publication_branch publication_sha publication_head
  shift || true
  unset ARKIRA_RECEIPT_IDENTITY_REPO ARKIRA_RECEIPT_IDENTITY_VALUE \
    ARKIRA_RECEIPT_IDENTITY_REPO_ARGUMENT ARKIRA_RECEIPT_STORE_IDENTITY ARKIRA_RECEIPT_STORE_DIR
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo=${2:-}; shift 2 ;;
      --tree) tree=${2:-}; shift 2 ;;
      --checks) checks=${2:-}; shift 2 ;;
      --candidate-tree) candidate_tree=${2:-}; shift 2 ;;
      --base) base=${2:-}; shift 2 ;;
      --base-branch) base_branch=${2:-}; shift 2 ;;
      --id) id=${2:-}; shift 2 ;;
      --full-ci) full_ci=true; shift ;;
      *) arkira_candidate_gate_error "unknown argument: $1"; return 1 ;;
    esac
  done
  [[ "$full_ci" == false || "$command" == certify || "$command" == validate ]] || {
    arkira_candidate_gate_error '--full-ci is valid only with certify or validate'
    return 1
  }
  [[ -z "$base_branch" || "$command" == certify || "$command" == validate || "$command" == require-committed || "$command" == publication-base || "$command" == publication-routing ]] || {
    arkira_candidate_gate_error '--base-branch is valid only with certify, validate, require-committed, publication-base, or publication-routing'
    return 1
  }
  [[ -n "$repo" ]] || { arkira_candidate_gate_error "$command requires --repo"; return 1; }
  case "$command" in
    certify) arkira_candidate_gate_certify "$repo" "$full_ci" "$base_branch" ;;
    validate)
      [[ "$full_ci" == true ]] || { arkira_candidate_gate_error 'validate requires --full-ci'; return 1; }
      arkira_candidate_gate_validate "$repo" "$base_branch"
      ;;
    accept) [[ -n "$tree" ]] || { arkira_candidate_gate_error 'accept requires --tree'; return 1; }; arkira_candidate_gate_accept "$repo" "$tree" ;;
    record-host-review) [[ -n "$tree" && -n "$checks" ]] || { arkira_candidate_gate_error 'record-host-review requires --tree and --checks'; return 1; }; arkira_candidate_gate_record_host_review "$repo" "$tree" "$checks" ;;
    require-staged) arkira_candidate_gate_require "$repo" staged ;;
    require-committed) arkira_candidate_gate_require "$repo" committed '' "$base" "$base_branch" ;;
    require-recorded) [[ -n "$candidate_tree" && -n "$base" ]] || { arkira_candidate_gate_error 'require-recorded requires --candidate-tree and --base'; return 1; }; arkira_candidate_gate_require "$repo" recorded "$candidate_tree" "$base" ;;
    publication-routing) arkira_candidate_gate_publication_routing "$repo" "$base" "$base_branch" ;;
    publication-base)
      publication_resolution="$(arkira_candidate_gate_publication_base "$repo" "$base_branch")" || return 1
      read -r publication_branch publication_sha publication_head <<< "$publication_resolution"
      printf '%s %s\n' "$publication_branch" "$publication_sha"
      ;;
    lineage-continue) [[ -n "$id" ]] || { arkira_candidate_gate_error 'lineage-continue requires --id'; return 1; }; arkira_candidate_gate_lineage_continue "$repo" "$id" ;;
    export-candidate) arkira_candidate_gate_export_candidate "$repo" ;;
    *) arkira_candidate_gate_error "unknown command: $command"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then arkira_candidate_gate_main "$@"; fi
