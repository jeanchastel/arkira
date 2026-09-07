#!/usr/bin/env bash
# Intent Layer: list candidate subsystem dirs (top 3 levels) with file counts.
# Usage: analyze-structure.sh [dir]   (default .)
# Stdout: TSV "depth\tdir\tfile_count".
# Exit: 0 ok; 2 bad path.
set -euo pipefail

root="${1:-.}"
if [ ! -d "$root" ]; then
  echo "usage: analyze-structure.sh [dir]" >&2
  exit 2
fi

find "$root" -mindepth 1 -maxdepth 3 \
  \( -name .git -o -name .arkira -o -name node_modules -o -name dist -o -name build -o -name .next -o -name vendor -o -name __pycache__ \) -prune \
  -o -type d -print | sort | while IFS= read -r d; do
    rel="${d#"$root"/}"
    depth=$(printf '%s' "$rel" | awk -F/ '{print NF-1}')
    count=$(find "$d" -maxdepth 1 -type f ! -name sync-state.json | wc -l | tr -d ' ')
    printf '%s\t%s\t%s\n' "$depth" "$d" "$count"
  done
