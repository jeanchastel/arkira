#!/usr/bin/env bash
set -euo pipefail

arkira_bug_report_error() {
  printf 'bug report: %s\n' "$*" >&2
}

arkira_bug_report_usage() {
  arkira_bug_report_error 'usage: bug-report.sh create <repo> --from-candidate-gate | bug-report.sh create <repo> --manual --title <text> --body-file <path> | bug-report.sh update <report> [--body-file <path>] [--status open|confirmed|fixed|wontfix] | bug-report.sh list [--status <status>|all]'
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
    s{\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b}{<REDACTED>}g;
  '
}

arkira_bug_report_prepare_dir() {
  local identity=${1:-} root reports directory
  root="$(arkira_receipt_runtime_root)"
  reports="$root/bug-reports"
  directory="$reports${identity:+/$identity}"
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

# Sets harness_version, harness_channel, and harness_sha in the caller's scope.
arkira_bug_report_harness() {
  harness_version=${ARKIRA_HARNESS_VERSION:-}
  [[ -n "$harness_version" ]] \
    || harness_version="$(jq -r '.version // "unknown"' "$ARKIRA_BUG_REPORT_DIR/../../.claude-plugin/plugin.json" 2>/dev/null || printf unknown)"
  harness_channel=${ARKIRA_HARNESS_CHANNEL:-dev/unreleased}
  harness_sha=${ARKIRA_HARNESS_SHA:-}
  [[ -n "$harness_sha" ]] \
    || harness_sha="$(git -C "$ARKIRA_BUG_REPORT_DIR/../.." rev-parse HEAD 2>/dev/null || printf unavailable)"
}

# Prints the front-matter value of key from a report, or nothing.
arkira_bug_report_field() {
  awk -v key="$2" 'NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    NR > 1 && index($0, key ": ") == 1 { print substr($0, length(key) + 3); exit }' "$1"
}

arkira_bug_report_write() {
  local target=$1 content=$2 stage
  stage="$(mktemp "$(dirname -- "$target")/.bug-report.XXXXXX")" || return 1
  if ! printf '%s\n' "$content" > "$stage" || ! chmod 600 "$stage" || ! mv -f -- "$stage" "$target"; then
    rm -f -- "$stage"
    return 1
  fi
}

arkira_bug_report_manual() {
  local repo=$1 title=$2 body_file=$3 identity name slug directory target existing section
  local harness_version harness_channel harness_sha session body created_at
  [[ -n "$title" && "$title" != *$'\n'* ]] \
    || { arkira_bug_report_error 'title must be one non-empty line'; return 1; }
  [[ -f "$body_file" && ! -L "$body_file" ]] \
    || { arkira_bug_report_error 'body file must be a regular non-symlink file'; return 1; }
  for section in Command Error Evidence Expected Workaround; do
    grep -Eq "^## $section\b" "$body_file" \
      || { arkira_bug_report_error "body file is missing the '## $section' section"; return 1; }
  done
  repo="$(cd -- "$repo" && pwd -P)" \
    || { arkira_bug_report_error 'repository path could not be resolved'; return 1; }
  git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1 \
    || { arkira_bug_report_error 'repository path is not a Git work tree'; return 1; }
  identity="$(arkira_receipt_repo_identity "$repo")" \
    || { arkira_bug_report_error 'repository identity could not be resolved'; return 1; }
  name="$(git -C "$repo" remote get-url origin 2>/dev/null || git -C "$repo" rev-parse --show-toplevel)"
  name="${name##*/}"; name="${name%.git}"
  slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//' | cut -c1-60 | sed -E 's/-+$//')"
  [[ -n "$slug" ]] || { arkira_bug_report_error 'title must contain letters or digits'; return 1; }
  directory="$(arkira_bug_report_prepare_dir)" \
    || { arkira_bug_report_error 'could not prepare private bug-report directory'; return 1; }
  for existing in "$directory"/*-"$name-$slug".md; do
    [[ -f "$existing" && ! -L "$existing" ]] || continue
    case "$(arkira_bug_report_field "$existing" status)" in
      open|confirmed)
        arkira_bug_report_error "an open report already covers this bug: $existing (use bug-report update)"
        return 1
        ;;
    esac
  done
  target="$directory/$(date -u '+%Y-%m-%d')-$name-$slug.md"
  [[ ! -e "$target" && ! -L "$target" ]] \
    || { arkira_bug_report_error "bug-report target already exists: $target"; return 1; }
  arkira_bug_report_harness
  session=${ARKIRA_RELEASE_SESSION:-unknown}
  created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  # Only operator-supplied text is redacted; the header holds computed metadata.
  title="$(printf '%s' "$title" | arkira_bug_report_redact)"
  body="$(arkira_bug_report_redact < "$body_file")"
  arkira_bug_report_write "$target" "---
title: $title
status: open
repo: $name
repo_identity: $identity
session: $session
harness_version: $harness_version
harness_sha: $harness_sha
harness_channel: $harness_channel
created: $created_at
---

$body" || { arkira_bug_report_error 'could not write bug report'; return 1; }
  printf 'Bug report: %s\n' "$target"
}

arkira_bug_report_update() {
  local report=$1 status=$2 body_file=$3 reports content
  [[ -n "$status" || -n "$body_file" ]] || { arkira_bug_report_usage; return 1; }
  case "$status" in ''|open|confirmed|fixed|wontfix) ;;
    *) arkira_bug_report_error 'status must be open, confirmed, fixed, or wontfix'; return 1 ;;
  esac
  reports="$(arkira_bug_report_prepare_dir)" \
    || { arkira_bug_report_error 'could not prepare private bug-report directory'; return 1; }
  [[ -f "$report" && ! -L "$report" ]] \
    || { arkira_bug_report_error 'report must be a regular non-symlink file'; return 1; }
  reports="$(cd -- "$reports" && pwd -P)" || return 1
  report="$(cd -- "$(dirname -- "$report")" && pwd -P)/${report##*/}"
  case "$report" in "$reports"/*.md) ;;
    *) arkira_bug_report_error "report must be a Markdown file under $reports"; return 1 ;;
  esac
  if [[ -n "$body_file" ]]; then
    [[ -f "$body_file" && ! -L "$body_file" ]] \
      || { arkira_bug_report_error 'body file must be a regular non-symlink file'; return 1; }
  fi
  content="$(cat -- "$report")"
  if [[ -n "$status" ]]; then
    if [[ -n "$(arkira_bug_report_field "$report" status)" ]]; then
      content="$(printf '%s\n' "$content" | awk -v status="$status" \
        'NR > 1 && !done && /^status: / { $0 = "status: " status; done = 1 } { print }')"
    else
      # Candidate-gate reports have no front matter; give them one for triage.
      content="---"$'\n'"status: $status"$'\n'"---"$'\n\n'"$content"
    fi
  fi
  if [[ -n "$body_file" ]]; then
    content+=$'\n\n'"## Update $(date -u '+%Y-%m-%dT%H:%M:%SZ')"$'\n\n'"$(arkira_bug_report_redact < "$body_file")"
  fi
  arkira_bug_report_write "$report" "$content" || { arkira_bug_report_error 'could not update bug report'; return 1; }
  printf 'Bug report: %s\n' "$report"
}

arkira_bug_report_list() {
  local wanted=${1:-} reports report status found=false
  reports="$(arkira_bug_report_prepare_dir)" \
    || { arkira_bug_report_error 'could not prepare private bug-report directory'; return 1; }
  while IFS= read -r report; do
    status="$(arkira_bug_report_field "$report" status)"
    status=${status:-open}
    case "${wanted:-active}" in
      all) ;;
      active) [[ "$status" == open || "$status" == confirmed ]] || continue ;;
      *) [[ "$status" == "$wanted" ]] || continue ;;
    esac
    found=true
    printf '%s\t%s\t%s\t%s\n' "$status" "$(arkira_bug_report_field "$report" repo)" \
      "$(arkira_bug_report_field "$report" title)" "$report"
  done < <(find "$reports" -type f -name '*.md' ! -name '.*' | LC_ALL=C sort)
  [[ "$found" == true ]] || printf 'No matching bug reports in %s\n' "$reports"
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

  arkira_bug_report_harness

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

arkira_bug_report_main() {
  local command=${1:-}
  case "$command" in
    create)
      if [[ "${3:-}" == --manual ]]; then
        local repo=${2:-} title='' body_file=''
        shift 3
        while [[ $# -ge 2 ]]; do
          case "$1" in
            --title) title=$2 ;;
            --body-file) body_file=$2 ;;
            *) arkira_bug_report_usage; return 1 ;;
          esac
          shift 2
        done
        [[ $# -eq 0 && -n "$repo" && -n "$title" && -n "$body_file" ]] || { arkira_bug_report_usage; return 1; }
        arkira_bug_report_manual "$repo" "$title" "$body_file"
        return
      fi
      [[ $# -eq 3 ]] || { arkira_bug_report_usage; return 1; }
      arkira_bug_report_create "$2" "$3"
      ;;
    update)
      local report=${2:-} status='' body_file=''
      [[ -n "$report" ]] || { arkira_bug_report_usage; return 1; }
      shift 2
      while [[ $# -ge 2 ]]; do
        case "$1" in
          --status) status=$2 ;;
          --body-file) body_file=$2 ;;
          *) arkira_bug_report_usage; return 1 ;;
        esac
        shift 2
      done
      [[ $# -eq 0 ]] || { arkira_bug_report_usage; return 1; }
      arkira_bug_report_update "$report" "$status" "$body_file"
      ;;
    list)
      [[ $# -eq 1 || ( $# -eq 3 && "$2" == --status ) ]] || { arkira_bug_report_usage; return 1; }
      arkira_bug_report_list "${3:-}"
      ;;
    *) arkira_bug_report_usage; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then arkira_bug_report_main "$@"; fi
