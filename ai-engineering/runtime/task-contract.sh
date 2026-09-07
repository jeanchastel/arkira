#!/usr/bin/env bash
set -uo pipefail

ARKIRA_TASK_CONTRACT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ARKIRA_TASK_CONTRACT_SCHEMA="$ARKIRA_TASK_CONTRACT_DIR/schemas/task-contract.json"
# shellcheck disable=SC1091  # Resolved relative to this runtime at execution.
. "$ARKIRA_TASK_CONTRACT_DIR/role-runtime.sh"
# shellcheck source=ai-engineering/runtime/receipt-lib.sh
. "$ARKIRA_TASK_CONTRACT_DIR/receipt-lib.sh"

arkira_task_contract_validate() {
  local contract=${1:-} path sha version content_digest ui_mode review_url
  [[ -f "$contract" && ! -L "$contract" ]] || {
    arkira_error 16 "task contract must be a regular non-symlink file"
    return
  }
  jq -e -s 'length == 1 and (.[0] | type) == "object"' "$contract" >/dev/null 2>&1 || {
    arkira_error 16 "task contract must contain one JSON object"
    return
  }
  [[ "$(jq -r '.schema_version // empty' "$contract")" == 2 ]] || {
    arkira_error 16 "new dispatch requires task contract schema version 2"
    return
  }
  arkira_validate_json_schema "$ARKIRA_TASK_CONTRACT_SCHEMA" "$contract" || {
    arkira_error 16 "task contract does not match its schema"
    return
  }
  case "$(jq -r '.verification.focused_check' "$contract")" in
    *run-all-tests.sh*)
      arkira_error 16 "task contract focused_check must name a single suite, not a group run; see scripts/test-suites.tsv"
      return
      ;;
  esac
  [[ "$(jq '.scope.allowed | length' "$contract")" -gt 0 ]] || {
    arkira_error 16 "task contract scope.allowed must not be empty"
    return
  }
  while IFS= read -r path; do
    arkira_validate_relative_path "$path" || {
      arkira_error 16 "task contract scope contains an unsafe path"
      return
    }
  done < <(jq -r '.scope.allowed[], .scope.protected[], .scope.adopted[]' "$contract")
  sha="$(jq -r '.harness.sha' "$contract")"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || {
    arkira_error 16 "task contract harness sha must be 40 lowercase hexadecimal characters"
    return
  }
  version="$(jq -r '.harness.version' "$contract")"
  [[ "$version" == unreleased || "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    arkira_error 16 "task contract harness version must be semantic or unreleased"
    return
  }
  content_digest="$(jq -r '.harness.content_digest' "$contract")"
  [[ "$content_digest" =~ ^[0-9a-f]{64}$ ]] || {
    arkira_error 16 "task contract harness content digest must be 64 lowercase hexadecimal characters"
    return
  }
  ui_mode="$(jq -r '.ui.mode' "$contract")"
  review_url="$(jq -r '.ui.review_url' "$contract")"
  case "$ui_mode" in
    local-review)
      [[ "$(jq '.ui.dev_command | length' "$contract")" -gt 0 ]] || {
        arkira_error 16 "local review requires a nonempty argv dev command"
        return
      }
      [[ "$review_url" =~ ^http://(localhost|127\.0\.0\.1)(:[1-9][0-9]{0,4})?(/.*)?$ ]] || {
        arkira_error 16 "local review URL must use localhost or 127.0.0.1"
        return
      }
      ;;
    none|inspect)
      [[ "$(jq '.ui.dev_command | length' "$contract")" -eq 0 && -z "$review_url" ]] || {
        arkira_error 16 "non-running UI modes require an empty dev command and review URL"
        return
      }
      ;;
    browser)
      if [[ -n "$review_url" && ! "$review_url" =~ ^http://(localhost|127\.0\.0\.1)(:[1-9][0-9]{0,4})?(/.*)?$ ]]; then
        arkira_error 16 "browser review URL must use localhost or 127.0.0.1"
        return
      fi
      ;;
  esac
}

arkira_task_contract_render() {
  local contract=${1:-}
  arkira_task_contract_validate "$contract" || return
  jq -r '
    "\(.objective)\n\n" +
    "## Accept\n" + (.acceptance | map("- " + .) | join("\n")) + "\n\n" +
    "## Non-goals\n" + (.non_goals | map("- " + .) | join("\n")) + "\n\n" +
    "## Scope\n" +
    "allow: \(.scope.allowed | if length == 0 then "none" else join(", ") end)\n" +
    "protect: \(.scope.protected | if length == 0 then "none" else join(", ") end)\n" +
    "adopt: \(.scope.adopted | if length == 0 then "none" else join(", ") end)\n\n" +
    "## Verify\n" +
    "tier: \(.verification.tier)\n" +
    "check: \(.verification.focused_check)\n" +
    "ui: \(.ui.mode |
      if . == "none" then "none"
      elif . == "inspect" then "inspect, check the rendered journey without a browser pass"
      elif . == "local-review" then "local-review, pause for exact-candidate operator acceptance"
      else "browser, one desktop and one mobile viewport over the changed journey only"
      end)\n" +
    "dev: \(.ui.dev_command | @json)\n" +
    "review: \(.ui.review_url | if length == 0 then "none" else . end)\n\n" +
    "## Run\n" +
    "harness: \(.harness.sha) v\(.harness.version) \(.harness.channel) \(.harness.content_digest)\n" +
    "model: \(.dispatch.model)\n" +
    "effort: \(.dispatch.effort)\n\n" +
    "## Skills\n" +
    (.skills |
      if length == 0 then "none"
      else map(
        if . == "ponytail" then
          "ponytail: smallest change that works; reuse what exists; no speculative abstraction"
        elif . == "caveman" then
          "caveman: terse output; no narration; read only what the task needs"
        elif . == "base-ui" then
          "base-ui: Base UI primitives for new interface work; keep an existing design system"
        elif . == "vercel" then
          "vercel: current official Vercel and Next.js documentation for version-specific claims"
        elif . == "impeccable" then
          "impeccable: material UI needs interaction, accessibility, keyboard, loading, empty, error, and responsive states"
        else . end
      ) | join("\n") end)
  ' "$contract"
}

arkira_task_contract_canonical() {
  jq -S -c . "${1:-}"
}

arkira_task_contract_digest() {
  arkira_task_contract_canonical "${1:-}" | arkira_receipt_sha256
}

arkira_task_contract_store_dir() {
  local identity=${1:-} root contracts directory
  [[ "$identity" =~ ^[a-f0-9]{64}$ ]] || return 1
  root="$(arkira_receipt_runtime_root)"
  contracts="$root/contracts"
  directory="$contracts/$identity"
  [[ ! -L "$root" && ! -L "$contracts" && ! -L "$directory" ]] || return 1
  mkdir -p -- "$directory" || return 1
  [[ -d "$root" && -d "$contracts" && -d "$directory" ]] || return 1
  [[ ! -L "$root" && ! -L "$contracts" && ! -L "$directory" ]] || return 1
  chmod 700 "$root" "$contracts" "$directory" || return 1
  printf '%s' "$directory"
}

arkira_task_contract_bind() {
  local repo=${1:-} contract=${2:-} canonical digest identity directory target stage
  arkira_task_contract_validate "$contract" || return
  canonical="$(arkira_task_contract_canonical "$contract")" || return 1
  digest="$(printf '%s\n' "$canonical" | arkira_receipt_sha256)" || return 1
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  directory="$(arkira_task_contract_store_dir "$identity")" || return 1
  target="$directory/$digest.json"
  [[ ! -L "$target" ]] || return 1
  if [[ -e "$target" ]]; then
    [[ -f "$target" ]] || return 1
    arkira_task_contract_load "$repo" "$digest" >/dev/null || return 1
    printf '%s\n' "$digest"
    return 0
  fi
  stage="$(mktemp "$directory/.contract.XXXXXX")" || return 1
  if ! jq -cn --arg repo_identity "$identity" --arg contract_digest "$digest" \
    --argjson contract "$canonical" \
    '{schema_version:1,repo_identity:$repo_identity,contract_digest:$contract_digest,contract:$contract}' \
    > "$stage"; then
    rm -f -- "$stage"
    return 1
  fi
  chmod 600 "$stage" || { rm -f -- "$stage"; return 1; }
  [[ ! -e "$target" && ! -L "$target" ]] || { rm -f -- "$stage"; return 1; }
  mv -f -- "$stage" "$target" || { rm -f -- "$stage"; return 1; }
  printf '%s\n' "$digest"
}

arkira_task_contract_load() {
  local repo=${1:-} digest=${2:-} identity directory target canonical actual
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  directory="$(arkira_task_contract_store_dir "$identity")" || return 1
  target="$directory/$digest.json"
  [[ -f "$target" && ! -L "$target" ]] || return 1
  jq -e --arg identity "$identity" --arg digest "$digest" '
    .schema_version == 1 and .repo_identity == $identity and
    .contract_digest == $digest and (.contract | type == "object")
  ' "$target" >/dev/null 2>&1 || return 1
  canonical="$(jq -S -c '.contract' "$target" 2>/dev/null)" || return 1
  actual="$(printf '%s\n' "$canonical" | arkira_receipt_sha256)" || return 1
  [[ "$actual" == "$digest" ]] || return 1
  printf '%s\n' "$canonical"
}

arkira_task_contract_usage() {
  printf 'usage: task-contract.sh validate|render <file> | bind|load <repo> <file-or-digest>\n' >&2
  return 2
}

arkira_task_contract_main() {
  local command=${1:-}
  case "$command" in
    validate) [[ "$#" -eq 2 ]] || { arkira_task_contract_usage; return; }; arkira_task_contract_validate "$2" ;;
    render) [[ "$#" -eq 2 ]] || { arkira_task_contract_usage; return; }; arkira_task_contract_render "$2" ;;
    bind) [[ "$#" -eq 3 ]] || { arkira_task_contract_usage; return; }; arkira_task_contract_bind "$2" "$3" ;;
    load) [[ "$#" -eq 3 ]] || { arkira_task_contract_usage; return; }; arkira_task_contract_load "$2" "$3" ;;
    *) arkira_task_contract_usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then arkira_task_contract_main "$@"; fi
