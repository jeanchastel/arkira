#!/usr/bin/env bash
# Recorded transform: run one host command from the repository root and write a
# transformer receipt for its output, only when every changed path matches the
# committed authoring.transform_paths. It never reverts the working tree.
set -uo pipefail

# shellcheck source=ai-engineering/runtime/candidate-gate.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/candidate-gate.sh"

die() {
  printf 'arkira transform: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 3 && "$2" == -- ]] || die 'usage: bin/arkira transform <repo> -- <command> [args...]'
repo=$1
shift 2
top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || die 'target is not a Git repository'
top="$(cd -- "$top" && pwd -P)" || die 'repository root could not be resolved'
arkira_candidate_gate_transform_paths "$top" HEAD committed || exit 1
if ((${#ARKIRA_CANDIDATE_GATE_TRANSFORM_PATHS[@]} == 0)); then
  printf 'arkira transform: committed .arkira/config.json declares no authoring.transform_paths; nothing can be recorded\n' >&2
  printf 'fix: add authoring.transform_paths to .arkira/config.json listing the globs the command may change, for example ["package.json", "pnpm-lock.yaml"], and merge that change to main in its own pull request first, because the candidate gate reads the list from the trusted base\n' >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/arkira-transform.XXXXXX")" || die 'temporary directory could not be created'
trap 'rm -rf -- "$work"' EXIT
arkira_receipt_snapshot "$top" "$work/pre.json" || die 'working tree snapshot failed before the command'
status=0
(cd -- "$top" && exec "$@") || status=$?
((status == 0)) || die "command exited $status; no receipt written"
arkira_receipt_snapshot "$top" "$work/post.json" || die 'working tree snapshot failed after the command'

changed=()
offending=()
while IFS= read -r -d '' path; do
  changed+=("$path")
  arkira_candidate_gate_transform_path_allowed "$path" || offending+=("$path")
done < <(jq -nj --slurpfile pre "$work/pre.json" --slurpfile post "$work/post.json" '
  def state: if . == null or .exists != true then {exists:false} else {exists:true,blob,mode} end;
  def as_map: reduce .[] as $entry ({}; .[$entry.path] = ($entry | state));
  ($pre[0].entries | as_map) as $before | ($post[0].entries | as_map) as $after |
  ($before + $after | keys[]) as $path |
  select(($before[$path] // {exists:false}) != ($after[$path] // {exists:false})) | $path, "\u0000"
')
((${#changed[@]})) || die 'command changed no paths; no receipt written'
if ((${#offending[@]})); then
  printf 'arkira transform: changed paths outside authoring.transform_paths; no receipt written:\n' >&2
  printf '  %s\n' "${offending[@]}" >&2
  exit 1
fi

argv_digest="$( { printf '%s' "$1"; (($# == 1)) || printf '\0%s' "${@:2}"; } | arkira_receipt_sha256)" \
  || die 'command digest failed'
metadata="$(jq -cn --arg job_id "transform-${argv_digest:0:12}-$(date '+%s')-$$" '
  {author_role:"transformer",author_provider:"host-command",author_model:"",author_effort:"none",job_id:$job_id}
')" || die 'receipt metadata could not be built'
receipt="$(arkira_receipt_write "$top" "$work/pre.json" "$work/post.json" "$metadata")" \
  || die 'receipt could not be written'
# A receipt-*.json name would be read as a receipt, so the sidecar takes a command- prefix.
sidecar="${receipt%/*}/command-${receipt##*/receipt-}"
if ! (umask 077 && printf '%s\0' "$@" | jq -Rs 'split("\u0000") | .[:-1]' > "$sidecar") \
  || ! chmod 600 "$sidecar"; then
  rm -f -- "$receipt" "$sidecar"
  die 'command record could not be written; receipt withdrawn'
fi
printf '%s\n' "$receipt"
