#!/usr/bin/env bash
# Validates an arkira switches.json against the v1 schema.
set -uo pipefail

file="${1:-}"
if [[ -z "$file" ]]; then
  echo "usage: validate-switches.sh <path-to-switches.json>" >&2
  exit 2
fi
if [[ ! -f "$file" ]]; then
  echo "switches.json not found at: $file" >&2
  exit 1
fi
if ! jq -e . "$file" >/dev/null 2>&1; then
  echo "switches.json is not valid JSON: $file" >&2
  exit 1
fi

required='["id","default","category","summary","description","policy_ref","settings_json_patch","introduced_in"]'

# Required fields present on every entry.
missing="$(jq -r --argjson req "$required" '
  .switches // [] | to_entries[] |
  . as $e |
  ($req - ($e.value | keys)) as $missing |
  if ($missing | length) > 0 then
    "entry[\($e.key)] id=\($e.value.id // "?") missing: \($missing | join(","))"
  else
    empty
  end
' "$file")"
if [[ -n "$missing" ]]; then
  echo "$missing" >&2
  exit 1
fi

# Duplicate ids.
dupes="$(jq -r '
  .switches // [] | map(.id) | group_by(.) |
  map(select(length > 1) | .[0]) | .[]
' "$file")"
if [[ -n "$dupes" ]]; then
  echo "duplicate switch ids: $dupes" >&2
  exit 1
fi

# Semver on introduced_in: MAJOR.MINOR.PATCH.
bad_semver="$(jq -r '
  .switches // [] |
  map(select((.introduced_in | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) | not)) |
  .[].id
' "$file")"
if [[ -n "$bad_semver" ]]; then
  echo "invalid semver on introduced_in for: $bad_semver" >&2
  exit 1
fi

# settings_json_patch.pointer must start with / when patch is present (null is allowed).
bad_ptr="$(jq -r '
  .switches // [] |
  map(select(.settings_json_patch != null
             and ((.settings_json_patch.pointer // "") | startswith("/") | not))) |
  .[].id
' "$file")"
if [[ -n "$bad_ptr" ]]; then
  echo "invalid JSON Pointer (must start with /) on: $bad_ptr" >&2
  exit 1
fi

exit 0
