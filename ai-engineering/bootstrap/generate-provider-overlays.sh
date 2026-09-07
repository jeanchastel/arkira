#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
adapter_dir="${ARKIRA_ADAPTERS_DIR:-$root/ai-engineering/adapters}"
output_dir=${1:-}
[[ -n "$output_dir" && -d "$output_dir" && ! -L "$output_dir" ]] || {
  printf 'usage: generate-provider-overlays.sh <existing-output-dir>\n' >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || exit 1
seen=""
for adapter in "$adapter_dir"/*.json; do
  [[ -f "$adapter" && ! -L "$adapter" ]] || continue
  [[ "$(basename -- "$adapter")" == schema.json ]] && continue
  context="$(jq -r '.context_file // empty' "$adapter")"
  [[ -n "$context" && "$context" != AGENTS.md ]] || continue
  [[ "$context" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.md$ ]] || {
    printf 'ERROR: unsafe adapter context_file in %s\n' "$adapter" >&2
    exit 1
  }
  if printf '%s' "$seen" | grep -Fxq -- "$context"; then
    printf 'ERROR: duplicate adapter context_file: %s\n' "$context" >&2
    exit 1
  fi
  seen+="$context"$'\n'
  display="$(jq -r '.display_name' "$adapter")"
  [[ -n "$display" ]] || exit 1
  # shellcheck disable=SC2016  # Backticks are literal Markdown.
  body="$(printf 'READ FIRST: `AGENTS.md` is the repository shared, normative context.\n\n%s uses the configured Arkira role contracts in `AGENTS.md`; this provider overlay adds no separate policy.\n\nPut subsystem context in the nearest child `AGENTS.md`, never in another provider-specific context file.' "$display")"
  sha="$(printf '%s' "$body" | shasum -a 256 | awk '{print $1}')"
  target="$output_dir/$context"
  temp="$(mktemp "$output_dir/.provider-overlay.XXXXXX")"
  {
    printf '# %s Context\n\n' "$display"
    printf '<!-- ARKIRA:MANAGED START id=tool-role-pointer v=1 sha=%s -->\n' "$sha"
    printf '%s\n' "$body"
    printf '<!-- ARKIRA:MANAGED END id=tool-role-pointer -->\n'
  } > "$temp"
  chmod 644 "$temp"
  mv -f -- "$temp" "$target"
  printf '%s\t%s\n' "$context" "$target"
done
