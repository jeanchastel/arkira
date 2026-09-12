#!/usr/bin/env bash
# Build or verify an attested archive from one exact, clean committed candidate.
set -uo pipefail

mode="${1:-}"
[ "$#" -gt 0 ] && shift
repo=""
candidate=""
output_dir=""
archive=""
provenance=""
usage() {
  printf 'usage: %s create --repo PATH --candidate SHA --output-dir PATH\n' "$0" >&2
  printf '       %s verify --repo PATH --candidate SHA --archive FILE --provenance FILE\n' "$0" >&2
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || { usage; exit 2; }; repo="$2"; shift 2 ;;
    --candidate) [ "$#" -ge 2 ] || { usage; exit 2; }; candidate="$2"; shift 2 ;;
    --output-dir) [ "$#" -ge 2 ] || { usage; exit 2; }; output_dir="$2"; shift 2 ;;
    --archive) [ "$#" -ge 2 ] || { usage; exit 2; }; archive="$2"; shift 2 ;;
    --provenance) [ "$#" -ge 2 ] || { usage; exit 2; }; provenance="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
case "$mode" in create|verify) ;; *) usage; exit 2 ;; esac
[ -n "$repo" ] && [ -n "$candidate" ] || { usage; exit 2; }
repo="$(cd -- "$repo" 2>/dev/null && pwd -P)" || {
  printf 'FAIL: repository is unavailable.\n' >&2
  exit 1
}

case "$candidate" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) printf 'FAIL: candidate must be an exact 40-character commit SHA.\n' >&2; exit 1 ;;
esac
resolved="$(git -C "$repo" rev-parse --verify "$candidate^{commit}" 2>/dev/null)"
[ "$resolved" = "$candidate" ] || { printf 'FAIL: candidate commit does not resolve exactly.\n' >&2; exit 1; }
if [ -n "$(git -C "$repo" status --porcelain --untracked-files=all)" ]; then
  printf 'FAIL: candidate repository is dirty; commit the complete candidate first.\n' >&2
  exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/arkira-provenance.XXXXXX")" || exit 1
cleanup_provenance() { rm -rf "$tmp"; }
trap cleanup_provenance EXIT HUP INT TERM

all_paths="$tmp/all-paths"
payload="$tmp/payload.txt"
git -C "$repo" ls-tree -r --name-only "$candidate" > "$all_paths" || exit 1
: > "$payload"
while IFS= read -r path; do
  case "/$path/" in
    */.git/*|*/.arkira/*|*/.claude/*|*/.codex/*|*/.agents/*|*/.code-review-graph/*|*/.codebase-memory/*|*/node_modules/*|*/__pycache__/*|*/.cache/*|*/.npm/*|*/.pnpm-store/*|*/.yarn/*|*/.pytest_cache/*|*/.mypy_cache/*|*/.ruff_cache/*|*/cache/*|*/caches/*|*/logs/*|*/tmp/*|*/temp/*) continue ;;
  esac
  case "$path" in
    *.log|*.lock|*.lockb|*.tmp|*.swp|*.swo|*.bak|*.orig|*.rej|*~|*/installed_plugins.json|installed_plugins.json|*/.DS_Store|.DS_Store|package-lock.json|pnpm-lock.yaml) continue ;;
  esac
  printf '%s\n' "$path" >> "$payload"
done < "$all_paths"
[ -s "$payload" ] || { printf 'FAIL: release payload is empty.\n' >&2; exit 1; }

version="$(git -C "$repo" show "$candidate:.claude-plugin/plugin.json" 2>/dev/null \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const v=JSON.parse(s).version;if(!/^\d+\.\d+\.\d+$/.test(v))process.exit(1);process.stdout.write(v)})')"
[ -n "$version" ] || { printf 'FAIL: candidate version is unavailable.\n' >&2; exit 1; }

payload_paths=()
while IFS= read -r path; do payload_paths+=("$path"); done < "$payload"
generated_archive="$tmp/arkira-$version.tar"
git -C "$repo" archive --format=tar --prefix="arkira-$version/" \
  --output="$generated_archive" "$candidate" "${payload_paths[@]}" || exit 1

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'
  fi
}
archive_sha="$(sha256_file "$generated_archive")"

if [ "$mode" = "create" ]; then
  [ -n "$output_dir" ] && [ -d "$output_dir" ] && [ ! -L "$output_dir" ] || {
    printf 'FAIL: output directory must be an existing regular directory.\n' >&2
    exit 1
  }
  final_archive="$output_dir/arkira-$version.tar"
  final_provenance="$output_dir/arkira-$version.provenance.json"
  [ ! -e "$final_archive" ] && [ ! -e "$final_provenance" ] || {
    printf 'FAIL: release artifacts already exist.\n' >&2
    exit 1
  }
  generated_json="$tmp/provenance.json"
  node - "$candidate" "$version" "$archive_sha" "$payload" > "$generated_json" <<'NODE'
const fs = require('fs')
const [candidate, version, archiveSha, inventoryPath] = process.argv.slice(2)
const payload = fs.readFileSync(inventoryPath, 'utf8').trim().split('\n').filter(Boolean)
process.stdout.write(JSON.stringify({
  schema: 1,
  candidate_sha: candidate,
  version,
  archive_sha256: archiveSha,
  payload_count: payload.length,
  payload_inventory: payload,
}, null, 2) + '\n')
NODE
  mv "$generated_archive" "$final_archive" || exit 1
  mv "$generated_json" "$final_provenance" || exit 1
  printf 'PASS: created attested archive for %s at %s.\n' "$candidate" "$final_archive"
  exit 0
fi

[ -n "$archive" ] && [ -f "$archive" ] && [ ! -L "$archive" ] || {
  printf 'FAIL: archive is unavailable.\n' >&2
  exit 1
}
[ -n "$provenance" ] && [ -f "$provenance" ] && [ ! -L "$provenance" ] || {
  printf 'FAIL: provenance is unavailable.\n' >&2
  exit 1
}
provided_sha="$(sha256_file "$archive")"
[ "$provided_sha" = "$archive_sha" ] || { printf 'FAIL: archive does not match committed candidate.\n' >&2; exit 1; }
node - "$provenance" "$candidate" "$version" "$archive_sha" "$payload" <<'NODE'
const fs = require('fs')
const [provenancePath, candidate, version, archiveSha, inventoryPath] = process.argv.slice(2)
const data = JSON.parse(fs.readFileSync(provenancePath, 'utf8'))
const payload = fs.readFileSync(inventoryPath, 'utf8').trim().split('\n').filter(Boolean)
if (data.schema !== 1 || data.candidate_sha !== candidate || data.version !== version ||
    data.archive_sha256 !== archiveSha || data.payload_count !== payload.length ||
    JSON.stringify(data.payload_inventory) !== JSON.stringify(payload)) process.exit(1)
NODE
json_rc=$?
[ "$json_rc" -eq 0 ] || { printf 'FAIL: provenance metadata does not match candidate.\n' >&2; exit 1; }
printf 'PASS: archive and provenance verify for %s.\n' "$candidate"
