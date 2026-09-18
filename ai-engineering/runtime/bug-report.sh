#!/usr/bin/env bash
set -euo pipefail

arkira_bug_report_error() {
  printf 'bug report: %s\n' "$*" >&2
}

arkira_bug_report_usage() {
  arkira_bug_report_error 'usage: bug-report.sh create <repo> --from-candidate-gate | bug-report.sh submit <bundle> --destination <configured-destination>'
}

ARKIRA_BUG_REPORT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=ai-engineering/runtime/receipt-lib.sh
. "$ARKIRA_BUG_REPORT_DIR/receipt-lib.sh"

arkira_bug_report_replace_literal() {
  local needle=${1:-} replacement=$2 pattern
  [[ -n "$needle" ]] || return 0
  pattern=${needle//\\/\\\\}
  pattern=${pattern//\*/\\*}
  pattern=${pattern//\?/\\?}
  pattern=${pattern//\[/\\[}
  content=${content//$pattern/$replacement}
}

arkira_bug_report_redact() {
  local content name value secret_name
  content="$(cat)"
  arkira_bug_report_replace_literal "$(arkira_receipt_runtime_root)" '<RUNTIME>'
  arkira_bug_report_replace_literal "${HOME:-}" '<HOME>'
  while IFS= read -r name; do
    case "$name" in
      ARKIRA_HARNESS_VERSION|ARKIRA_HARNESS_CHANNEL|ARKIRA_HARNESS_SHA) continue ;;
    esac
    value=${!name-}
    [[ -n "$value" ]] || continue
    secret_name=false
    [[ "$name" =~ (TOKEN|SECRET|PASSWORD|PASS|COOKIE|CREDENTIAL|AUTH|API_KEY|PRIVATE_KEY) ]] \
      && secret_name=true
    (( ${#value} >= 8 )) || "$secret_name" || continue
    arkira_bug_report_replace_literal "$value" '<REDACTED>'
  done < <(compgen -e)
  printf '%s' "$content" | perl -pe '
    s{\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b}{<REDACTED>}g;
    s{\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b}{<REDACTED>}g;
    s{((?:Bearer|Basic)\s+)[^\s"\047]+}{$1<REDACTED>}gi;
    s{((?:token|cookie|password|credential|secret|api[_-]?key)\s*[=:]\s*)[^\s,;]+}{$1<REDACTED>}gi;
  '
}

arkira_bug_report_prepare_dir() {
  local identity=$1 root reports directory
  root="$(arkira_receipt_runtime_root)"
  reports="$root/bug-reports"
  directory="$reports/$identity"
  arkira_receipt_reject_symlink_components "$root" || return 1
  arkira_receipt_reject_symlink_components "$reports" || return 1
  arkira_receipt_reject_symlink_components "$directory" || return 1
  mkdir -p -- "$directory" || return 1
  [[ -d "$root" && -d "$reports" && -d "$directory" ]] || return 1
  arkira_receipt_reject_symlink_components "$root" || return 1
  arkira_receipt_reject_symlink_components "$reports" || return 1
  arkira_receipt_reject_symlink_components "$directory" || return 1
  chmod 700 "$root" "$reports" "$directory" || return 1
  printf '%s' "$directory"
}

arkira_bug_report_local_record() {
  local root=$1 candidate=${2:-}
  [[ -n "$candidate" && -f "$candidate" && ! -L "$candidate" ]] || return 0
  case "$candidate" in
    "$root"/*) printf '%s' "$candidate" ;;
  esac
}

arkira_bug_report_create() {
  local repo=$1 source_flag=$2 identity root attestation_dir attestation='' candidate_tree trusted_base
  local candidate_gate diagnostic_command diagnostic_output diagnostic_status recorded_command=''
  local validation_record='' review_record='' lineage_record='' lineage_id='' path
  local harness_version harness_channel harness_sha directory report_id json_target markdown_target
  local json_stage markdown_stage commands_json evidence_json created_at sanitized

  [[ "$source_flag" == --from-candidate-gate ]] || { arkira_bug_report_usage; return 1; }
  repo="$(cd -- "$repo" && pwd -P)" \
    || { arkira_bug_report_error 'repository path could not be resolved'; return 1; }
  git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1 \
    || { arkira_bug_report_error 'repository path is not a Git work tree'; return 1; }
  identity="$(arkira_receipt_repo_identity "$repo")" \
    || { arkira_bug_report_error 'repository identity could not be resolved'; return 1; }
  root="$(arkira_receipt_runtime_root)"
  candidate_tree="$(git -C "$repo" write-tree)" || return 1
  attestation_dir="$root/attestations/$identity"
  if [[ -f "$attestation_dir/$candidate_tree.json" && ! -L "$attestation_dir/$candidate_tree.json" ]]; then
    attestation="$attestation_dir/$candidate_tree.json"
  elif [[ -d "$attestation_dir" && ! -L "$attestation_dir" ]]; then
    for path in "$attestation_dir"/*.json; do
      [[ -f "$path" && ! -L "$path" ]] || continue
      [[ -z "$attestation" || "$path" -nt "$attestation" ]] && attestation=$path
    done
  fi

  if [[ -n "$attestation" ]] && jq -e . "$attestation" >/dev/null 2>&1; then
    candidate_tree="$(jq -r '.candidate_tree // empty' "$attestation")"
    [[ "$candidate_tree" =~ ^[a-f0-9]{40}$ ]] \
      || candidate_tree="$(git -C "$repo" write-tree)"
    trusted_base="$(jq -r '.trusted_base // empty' "$attestation")"
    [[ "$trusted_base" =~ ^[a-f0-9]{40}$ ]] \
      || trusted_base="$(git -C "$repo" rev-parse HEAD)"
    recorded_command="$(jq -r '.validation.command // empty' "$attestation")"
    validation_record="$(arkira_bug_report_local_record "$root" \
      "$(jq -r '.validation_record // empty' "$attestation")")"
    review_record="$(arkira_bug_report_local_record "$root" \
      "$(jq -r '.review.evidence_record // empty' "$attestation")")"
    lineage_id="$(jq -r '.lineage.lineage_id // empty' "$attestation")"
    if [[ -n "$lineage_id" && -d "$root/lineages/$identity" && ! -L "$root/lineages/$identity" ]]; then
      for path in "$root/lineages/$identity"/*.json; do
        [[ -f "$path" && ! -L "$path" ]] || continue
        if jq -e --arg id "$lineage_id" '.lineage_id == $id' "$path" >/dev/null 2>&1; then
          lineage_record=$path
          break
        fi
      done
    fi
  else
    trusted_base="$(git -C "$repo" rev-parse HEAD)" || return 1
  fi

  candidate_gate="$ARKIRA_BUG_REPORT_DIR/candidate-gate.sh"
  printf -v diagnostic_command 'bash %q require-recorded --repo %q --candidate-tree %q --base %q' \
    "$candidate_gate" "$repo" "$candidate_tree" "$trusted_base"
  set +e
  diagnostic_output="$(bash "$candidate_gate" require-recorded --repo "$repo" \
    --candidate-tree "$candidate_tree" --base "$trusted_base" 2>&1)"
  diagnostic_status=$?
  set -e

  harness_version=${ARKIRA_HARNESS_VERSION:-}
  [[ -n "$harness_version" ]] \
    || harness_version="$(jq -r '.version // "unknown"' "$ARKIRA_BUG_REPORT_DIR/../../.claude-plugin/plugin.json" 2>/dev/null || printf unknown)"
  harness_channel=${ARKIRA_HARNESS_CHANNEL:-dev/unreleased}
  harness_sha=${ARKIRA_HARNESS_SHA:-}
  [[ -n "$harness_sha" ]] \
    || harness_sha="$(git -C "$ARKIRA_BUG_REPORT_DIR/../.." rev-parse HEAD 2>/dev/null || printf unavailable)"

  recorded_command="$(printf '%s' "$recorded_command" | arkira_bug_report_redact)"
  diagnostic_command="$(printf '%s' "$diagnostic_command" | arkira_bug_report_redact)"
  diagnostic_output="$(printf '%s' "$diagnostic_output" | arkira_bug_report_redact)"
  attestation="$(printf '%s' "$attestation" | arkira_bug_report_redact)"
  validation_record="$(printf '%s' "$validation_record" | arkira_bug_report_redact)"
  review_record="$(printf '%s' "$review_record" | arkira_bug_report_redact)"
  lineage_record="$(printf '%s' "$lineage_record" | arkira_bug_report_redact)"

  commands_json="$(jq -cn --arg recorded "$recorded_command" --arg diagnostic "$diagnostic_command" \
    --arg error_text "$diagnostic_output" --argjson exit_status "$diagnostic_status" '
      (if $recorded == "" then [] else
        [{source:"attestation.validation",command:$recorded,error_text:null,exit_status:null}]
       end) +
      [{source:"bug-report.local-diagnostic",command:$diagnostic,
        error_text:$error_text,exit_status:$exit_status}]
    ')" || return 1
  evidence_json="$(jq -cn --arg attestation "$attestation" --arg validation "$validation_record" \
    --arg lineage "$lineage_record" --arg review "$review_record" '
      {attestation:(if $attestation == "" then null else $attestation end),
       validation:(if $validation == "" then null else $validation end),
       lineage:(if $lineage == "" then null else $lineage end),
       review:(if $review == "" then null else $review end)}
    ')" || return 1

  directory="$(arkira_bug_report_prepare_dir "$identity")" \
    || { arkira_bug_report_error 'could not prepare private bug-report directory'; return 1; }
  report_id="report-$(date -u '+%Y%m%dT%H%M%SZ')-$$-${RANDOM}${RANDOM}"
  json_target="$directory/$report_id.json"
  markdown_target="$directory/$report_id.md"
  [[ ! -e "$json_target" && ! -L "$json_target" && ! -e "$markdown_target" && ! -L "$markdown_target" ]] \
    || { arkira_bug_report_error 'bug-report target already exists'; return 1; }
  json_stage="$(mktemp "$directory/.bug-report.XXXXXX")" || return 1
  markdown_stage="$(mktemp "$directory/.bug-report.XXXXXX")" || { rm -f -- "$json_stage"; return 1; }
  created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  jq -cn --arg report_id "$report_id" --arg created_at "$created_at" --arg identity "$identity" \
    --arg version "$harness_version" --arg channel "$harness_channel" --arg sha "$harness_sha" \
    --arg candidate_tree "$candidate_tree" --arg trusted_base "$trusted_base" \
    --argjson commands "$commands_json" --argjson evidence "$evidence_json" '
      {schema_version:1,report_id:$report_id,created_at:$created_at,source:"candidate-gate",
       repo_identity:$identity,harness:{version:$version,channel:$channel,sha:$sha},
       candidate_tree:$candidate_tree,trusted_base:$trusted_base,
       commands:$commands,evidence:$evidence,redaction:{mandatory:true,
       placeholders:["<HOME>","<RUNTIME>","<REDACTED>"]}}
    ' > "$json_stage" || { rm -f -- "$json_stage" "$markdown_stage"; return 1; }
  sanitized="$(jq -c . "$json_stage")" || { rm -f -- "$json_stage" "$markdown_stage"; return 1; }
  printf '%s\n' "$sanitized" > "$json_stage"
  jq -r '
    "# Arkira bug report\n\n" +
    "- Report: `\(.report_id)`\n" +
    "- Created: `\(.created_at)`\n" +
    "- Repository identity: `\(.repo_identity)`\n" +
    "- Harness: `\(.harness.version)` / `\(.harness.channel)` / `\(.harness.sha)`\n" +
    "- Candidate tree: `\(.candidate_tree)`\n" +
    "- Trusted base: `\(.trusted_base)`\n\n" +
    "## Commands and errors\n\n```json\n" + (.commands | tojson) + "\n```\n\n" +
    "## Local evidence references\n\n```json\n" + (.evidence | tojson) + "\n```\n\n" +
    "Redaction is mandatory. `<HOME>`, `<RUNTIME>`, and `<REDACTED>` replace sensitive source material.\n"
  ' "$json_stage" > "$markdown_stage" || { rm -f -- "$json_stage" "$markdown_stage"; return 1; }
  if ! chmod 600 "$json_stage" "$markdown_stage" \
    || ! mv -f -- "$json_stage" "$json_target" \
    || ! mv -f -- "$markdown_stage" "$markdown_target"; then
    rm -f -- "$json_stage" "$markdown_stage"
    return 1
  fi
  printf 'Bug report JSON: %s\nBug report Markdown: %s\n' "$json_target" "$markdown_target"
}

arkira_bug_report_submit() {
  local bundle=$1 destination_flag=$2 requested_destination=${3:-} configured_destination confirmation
  [[ "$destination_flag" == --destination && -n "$requested_destination" ]] \
    || { arkira_bug_report_usage; return 1; }
  configured_destination=${ARKIRA_BUG_REPORT_DESTINATION:-}
  [[ -n "$configured_destination" ]] \
    || { arkira_bug_report_error 'ARKIRA_BUG_REPORT_DESTINATION is not configured'; return 1; }
  [[ "$requested_destination" == "$configured_destination" ]] \
    || { arkira_bug_report_error 'destination does not match ARKIRA_BUG_REPORT_DESTINATION'; return 1; }
  [[ -f "$bundle" && ! -L "$bundle" ]] \
    || { arkira_bug_report_error 'bundle must be a regular non-symlink file'; return 1; }
  case "$requested_destination" in
    http://*|https://*) ;;
    /*)
      [[ -d "$(dirname -- "$requested_destination")" && ! -L "$requested_destination" ]] \
        || { arkira_bug_report_error 'configured destination path is not writable safely'; return 1; }
      ;;
    *) arkira_bug_report_error 'configured destination must be an absolute path or HTTP(S) URL'; return 1 ;;
  esac
  printf 'Complete outgoing payload:\n'
  cat -- "$bundle"
  printf 'Type submit to send this payload: ' >&2
  IFS= read -r confirmation || true
  [[ "$confirmation" == submit ]] \
    || { arkira_bug_report_error 'confirmation was not affirmative; nothing sent'; return 1; }
  case "$requested_destination" in
    http://*|https://*)
      curl --fail-with-body --silent --show-error \
        -H 'Content-Type: application/octet-stream' --data-binary "@$bundle" "$requested_destination"
      ;;
    *)
      local stage
      stage="$(mktemp "$(dirname -- "$requested_destination")/.arkira-bug-report.XXXXXX")" || return 1
      if ! cp -- "$bundle" "$stage" || ! chmod 600 "$stage" \
        || ! mv -f -- "$stage" "$requested_destination"; then
        rm -f -- "$stage"
        return 1
      fi
      ;;
  esac
}

arkira_bug_report_main() {
  local command=${1:-}
  case "$command" in
    create)
      [[ $# -eq 3 ]] || { arkira_bug_report_usage; return 1; }
      arkira_bug_report_create "$2" "$3"
      ;;
    submit)
      [[ $# -eq 4 ]] || { arkira_bug_report_usage; return 1; }
      arkira_bug_report_submit "$2" "$3" "$4"
      ;;
    *) arkira_bug_report_usage; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then arkira_bug_report_main "$@"; fi
