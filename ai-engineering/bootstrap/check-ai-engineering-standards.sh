#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <target-repo-path>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

target_input=$1

if [[ ! -e "$target_input" ]]; then
  echo "ERROR: Target repo path does not exist: $target_input" >&2
  exit 2
fi

if [[ ! -d "$target_input" ]]; then
  echo "ERROR: Target repo path is not a directory: $target_input" >&2
  exit 2
fi

if ! git -C "$target_input" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: Target path is not inside a Git repo: $target_input" >&2
  exit 2
fi

target_repo="$(git -C "$target_input" rev-parse --show-toplevel)"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
standards_repo="$(cd -- "$script_dir/../.." && pwd -P)"

# shellcheck source=ai-engineering/bootstrap/lib/sync-lib.sh
source "$script_dir/lib/sync-lib.sh"

if sync_uses_public_distribution "$target_repo"; then
  printf 'central-reference: legacy vendored-file sync is disabled; no files changed. Run arkira context <repo> to resolve shared controls.\n'
  exit 0
fi

KSEP="$SYNC_KSEP"

target_profile="$(sync_detect_target_profile "$target_repo")"

installed_path_for() {
  local canonical_file=$1
  local target_path=$2
  if [[ "$target_repo" == "$standards_repo" ]]; then
    printf '%s\n' "$canonical_file"
  else
    printf '%s/%s\n' "$target_repo" "$target_path"
  fi
}

block_status_counts() {
  local canonical_file=$1
  local installed_file=$2
  local clean=0 update_clean=0 drifted=0 missing=0 unknown=0 malformed=0
  local canonical_rows target_rows row id sha body_sha target_row target_sha

  canonical_rows="$(sync_parse_sentinels "$canonical_file" 2>/dev/null || true)"
  target_rows=""
  if [[ -f "$installed_file" ]]; then
    target_rows="$(sync_parse_sentinels "$installed_file" 2>/dev/null || true)" || true
    if [[ -z "$target_rows" ]] && grep -q "ARKIRA:MANAGED" "$installed_file"; then
      malformed=1
    fi
  fi

  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    id="$(printf '%s\n' "$row" | awk -F '\t' '{print $1}')"
    sha="$(printf '%s\n' "$row" | awk -F '\t' '{print $3}')"
    target_row="$(printf '%s\n' "$target_rows" | awk -F '\t' -v id="$id" '$1 == id {print; exit}')"
    if [[ -z "$target_row" ]]; then
      missing=$((missing + 1))
      continue
    fi
    target_sha="$(printf '%s\n' "$target_row" | awk -F '\t' '{print $3}')"
    body_sha="$(printf '%s\n' "$target_row" | awk -F '\t' '{print $6}')"
    if [[ "$target_sha" == "$body_sha" && "$body_sha" == "$sha" ]]; then
      clean=$((clean + 1))
    elif [[ "$target_sha" == "$body_sha" ]]; then
      update_clean=$((update_clean + 1))
    else
      drifted=$((drifted + 1))
    fi
    if [[ "$sha" != "$(printf '%s\n' "$row" | awk -F '\t' '{print $6}')" ]]; then
      unknown=$((unknown + 1))
    fi
  done <<<"$canonical_rows"

  if [[ -n "$target_rows" ]]; then
    while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      id="$(printf '%s\n' "$row" | awk -F '\t' '{print $1}')"
      if ! printf '%s\n' "$canonical_rows" | awk -F '\t' -v id="$id" '$1 == id {found=1} END {exit found ? 0 : 1}'; then
        unknown=$((unknown + 1))
      fi
    done <<<"$target_rows"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$clean" "$update_clean" "$drifted" "$missing" "$unknown" "$malformed"
}

printf '=== Standards files ===\n'
printf '%-35s %-18s %s\n' "File" "Status" "Action"

will_change=0
conflicts=0
prompts=0
pristine_baseline_keys=""

for check in "${SYNC_CHECKS[@]}"; do
  IFS='|' read -r source_path target_path profile_filter scope <<<"$check"
  if ! sync_profile_matches "${profile_filter:-*}" "$target_profile"; then
    continue
  fi
  sync_manifest_scope_installs "$check" "${scope:-}" || continue
  if [[ "$target_repo" == "$standards_repo" && "$source_path" == ai-engineering/root/* ]]; then
    continue
  fi
  canonical_file="$standards_repo/$source_path"
  if [[ ! -f "$canonical_file" ]]; then
    continue
  fi
  if sync_is_managed_block_document "$canonical_file"; then
    continue
  fi
  pristine_baseline_keys+="files${KSEP}${target_path}${KSEP}baseline_sha"$'\n'
done

exec 4< <(printf '%s' "$pristine_baseline_keys" | sync_registry_read_many "$target_repo")

for check in "${SYNC_CHECKS[@]}"; do
  IFS='|' read -r source_path target_path profile_filter scope <<<"$check"
  if ! sync_profile_matches "${profile_filter:-*}" "$target_profile"; then
    continue
  fi
  sync_manifest_scope_installs "$check" "${scope:-}" || continue
  # The repo-root context trio (AGENTS.md, CLAUDE.md, CODEX.md) is the standards
  # repo's own local-only context, not a sync target. When syncing the standards
  # repo against itself, skip the ai-engineering/root/* entries so sync never
  # classifies the repo-root trio as a source or target. See governance/sync-standard.md.
  if [[ "$target_repo" == "$standards_repo" && "$source_path" == ai-engineering/root/* ]]; then
    continue
  fi
  canonical_file="$standards_repo/$source_path"
  installed_file="$(installed_path_for "$canonical_file" "$target_path")"

  if [[ ! -f "$canonical_file" ]]; then
    printf '%-35s %-18s %s\n' "$target_path" "missing-source" "fix canonical source"
    conflicts=$((conflicts + 1))
    continue
  fi

  if sync_is_managed_block_document "$canonical_file"; then
    counts="$(block_status_counts "$canonical_file" "$installed_file")"
    IFS=$'\t' read -r clean update_clean drifted missing unknown malformed <<<"$counts"
    if [[ "$malformed" -gt 0 ]]; then
      status="malformed target"
      action="skip; repair sentinels"
      conflicts=$((conflicts + 1))
    elif [[ "$drifted" -gt 0 ]]; then
      status="$drifted blocks drifted"
      action="prompt on apply"
      prompts=$((prompts + drifted))
    elif [[ "$missing" -gt 0 ]]; then
      status="block missing"
      action="insert on apply"
      will_change=$((will_change + missing))
    elif [[ "$update_clean" -gt 0 ]]; then
      status="$update_clean blocks update-clean"
      action="update on apply"
      will_change=$((will_change + update_clean))
    elif [[ "$unknown" -gt 0 ]]; then
      status="$clean blocks clean"
      action="unknown target blocks left alone"
    else
      status="$clean blocks clean"
      action="none"
    fi
    printf '%-35s %-18s %s\n' "$target_path" "$status" "$action"
    continue
  fi

  # Consume this file's baseline before any bail-out below. The key list on fd 4
  # is positional, and loop 1 emits a line for every pristine canonical file
  # whether or not it exists in the target. Skipping a read here would shift
  # every later file onto the previous file's baseline.
  IFS= read -r baseline <&4 || baseline=""

  if [[ ! -f "$installed_file" ]]; then
    printf '%-35s %-18s %s\n' "$target_path" "missing" "create on apply"
    will_change=$((will_change + 1))
    continue
  fi

  status="$(sync_classify_pristine "$installed_file" "$canonical_file" "$baseline" 2>/dev/null || printf 'local-drift')"
  case "$status" in
    clean)
      action="none"
      ;;
    refresh-clean)
      action="baseline on apply"
      will_change=$((will_change + 1))
      ;;
    update-clean)
      action="update on apply"
      will_change=$((will_change + 1))
      ;;
    local-drift)
      if cmp -s "$installed_file" "$canonical_file"; then
        status="clean"
        action="baseline on apply"
      else
        action="skip; use --force-pristine"
        conflicts=$((conflicts + 1))
      fi
      ;;
    conflict)
      action="skip; use --force-pristine"
      conflicts=$((conflicts + 1))
      ;;
    *)
      action="skip"
      conflicts=$((conflicts + 1))
      ;;
  esac
  printf '%-35s %-18s %s\n' "$target_path" "$status" "$action"
done
exec 4<&-

printf '\n%s files will change. %s conflicts. %s prompts required.\n' "$will_change" "$conflicts" "$prompts"
exit 0
