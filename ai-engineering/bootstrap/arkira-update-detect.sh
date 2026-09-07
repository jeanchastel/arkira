#!/usr/bin/env bash
# Print ids of switches whose introduced_in > config.standards_version.
set -uo pipefail
cfg="${1:-}"
sw="${2:-}"
if [[ -z "$cfg" || -z "$sw" ]]; then
  echo "usage: arkira-update-detect.sh <config.json> <switches.json>" >&2; exit 2
fi
if [[ ! -f "$cfg" || ! -f "$sw" ]]; then
  echo "missing config or switches file" >&2; exit 1
fi

jq -r --slurpfile config "$cfg" '
  ($config[0].standards_version | split(".") | map(tonumber)) as $cur |
  .switches[] |
  ((.introduced_in | split(".") | map(tonumber)) as $iv |
   if $iv > $cur then .id else empty end)
' "$sw"
